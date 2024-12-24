# install dependencies:
#  sudo apt install cpanminus libjson-xs-perl libjson-perl libmysqlclient-dev libdbi-perl
#  sudo cpanm Net::WebSocket::Server
#  sudo cpanm DBD::MariaDB

use strict;
use warnings;
use JSON;
use Getopt::Long;
use DBI;
use Time::HiRes qw (time);
use Time::Local 'timegm_nocheck';

use Net::WebSocket::Server;
use Protocol::WebSocket::Frame;

$Protocol::WebSocket::Frame::MAX_PAYLOAD_SIZE = 100*1024*1024;
$Protocol::WebSocket::Frame::MAX_FRAGMENTS_AMOUNT = 102400;

$| = 1;

my $network;

my $port = 8800;

my $dsn = 'DBI:MariaDB:database=eosio_token_accounting;host=localhost';
my $db_user = 'eosio_token_accounting';
my $db_password = 'De3PhooL';
my $commit_every = 10;
my $endblock = 2**32 - 1;


my $ok = GetOptions
    ('network=s' => \$network,
     'port=i'    => \$port,
     'ack=i'     => \$commit_every,
     'endblock=i'  => \$endblock,
     'dsn=s'     => \$dsn,
     'dbuser=s'  => \$db_user,
     'dbpw=s'    => \$db_password,
    );


if( not $network or not $ok or scalar(@ARGV) > 0 )
{
    print STDERR "Usage: $0 --network=X [options...]\n",
        "Options:\n",
        "  --network=X        network name\n",
        "  --port=N           \[$port\] TCP port to listen to websocket connection\n",
        "  --ack=N            \[$commit_every\] Send acknowledgements every N blocks\n",
        "  --endblock=N       \[$endblock\] Stop before given block\n",
        "  --dsn=DSN          \[$dsn\]\n",
        "  --dbuser=USER      \[$db_user\]\n",
        "  --dbpw=PASSWORD    \[$db_password\]\n";
    exit 1;
}


my $dbh = DBI->connect($dsn, $db_user, $db_password,
                       {'RaiseError' => 1, AutoCommit => 0,
                        mariadb_server_prepare => 1});
die($DBI::errstr) unless $dbh;


my $sth_add_currency = $dbh->prepare
    ('INSERT IGNORE INTO ' . $network . '_CURRENCIES (contract, currency, decimals, multiplier) ' .
     'VALUES(?,?,?,?)');

my $sth_set_currency_issuer = $dbh->prepare
    ('UPDATE ' . $network . '_CURRENCIES SET issuer=? WHERE contract=? AND currency=?');

my $sth_add_bal = $dbh->prepare
    ('INSERT INTO ' . $network . '_BALANCES ' .
     '(account_name, contract, currency, balance, block_num, block_time, trx_id) ' .
     'VALUES(?,?,?,?,?,?,?) ' .
     'ON DUPLICATE KEY UPDATE balance=balance+?, block_num=?, block_time=?, trx_id=?');

my $sth_sub_bal = $dbh->prepare
    ('UPDATE ' . $network . '_BALANCES ' .
     'SET balance=balance-?, block_num=?, block_time=?, trx_id=?  ' .
     'WHERE account_name=? AND contract=? AND currency=?');

my $sth_add_xfer = $dbh->prepare
    ('INSERT INTO ' . $network . '_TRANSFERS ' .
     '(seq, block_num, block_time, trx_id, contract, currency, account_name, delta, balance, other_party, memo) ' .
     'VALUES(?,?,?,?,?,?,?,?, ' .
     ' (SELECT balance FROM ' . $network . '_BALANCES WHERE account_name=? AND contract=? AND currency=?), ?, ?)');


my $sth_add_failure = $dbh->prepare
    ('INSERT INTO ' . $network . '_FAILED_DECODING ' .
     '(seq, block_num, block_time, trx_id, contract) ' .
     'VALUES(?,?,?,?,?)');


my $sth_upd_sync = $dbh->prepare
    ('INSERT INTO SYNC (network, block_num, block_time) VALUES(?,?,?) ' .
     'ON DUPLICATE KEY UPDATE block_num=?, block_time=?');

my $committed_block = 0;
my $stored_block = 0;
my $uncommitted_block = 0;
{
    my $sth = $dbh->prepare
        ('SELECT block_num FROM SYNC WHERE network=?');
    $sth->execute($network);
    my $r = $sth->fetchall_arrayref();
    if( scalar(@{$r}) > 0 )
    {
        $stored_block = $r->[0][0];
        printf STDERR ("Starting from stored_block=%d\n", $stored_block);
    }
}


my %known_currency;
my %known_issuer;
{
    my $sth = $dbh->prepare ('SELECT contract, currency, issuer FROM ' . $network . '_CURRENCIES');
    $sth->execute();
    while( my $r = $sth->fetchrow_arrayref() )
    {
        $known_currency{$r->[0]}{$r->[1]} = 1;
        if( defined($r->[2]) )
        {
            $known_issuer{$r->[0]}{$r->[1]} = $r->[2];
        }
    }
}



my $json = JSON->new;

my $blocks_counter = 0;
my $actions_counter = 0;
my $counter_start = time();

Net::WebSocket::Server->new(
    listen => $port,
    on_connect => sub {
        my ($serv, $conn) = @_;
        $conn->on(
            'binary' => sub {
                my ($conn, $msg) = @_;
                my ($msgtype, $opts, $js) = unpack('VVa*', $msg);
                my $data = eval {$json->decode($js)};
                if( $@ )
                {
                    print STDERR $@, "\n\n";
                    print STDERR $js, "\n";
                    exit;
                }

                my $ack = process_data($msgtype, $data);
                if( $ack >= 0 )
                {
                    $conn->send_binary(sprintf("%d", $ack));
                    print STDERR "ack $ack\n";
                }

                if( $ack >= $endblock )
                {
                    print STDERR "Reached end block\n";
                    exit(0);
                }
            },
            'disconnect' => sub {
                my ($conn, $code) = @_;
                print STDERR "Disconnected: $code\n";
                $dbh->rollback();
                $committed_block = 0;
                $uncommitted_block = 0;
            },

            );
    },
    )->start;


sub process_data
{
    my $msgtype = shift;
    my $data = shift;

    if( $msgtype == 1001 ) # CHRONICLE_MSGTYPE_FORK
    {
        my $block_num = $data->{'block_num'};
        print STDERR "fork at $block_num\n";
        $uncommitted_block = 0;
        return $block_num-1;
    }
    elsif( $msgtype == 1003 ) # CHRONICLE_MSGTYPE_TX_TRACE
    {
        if( $data->{'block_num'} > $stored_block )
        {
            my $trace = $data->{'trace'};
            if( $trace->{'status'} eq 'executed' )
            {
                my $block_time = $data->{'block_timestamp'};
                $block_time =~ s/T/ /;

                my $tx = { block_num => $data->{'block_num'},
                           block_time => $block_time,
                           trx_id => $trace->{'id'} };

                foreach my $atrace (@{$trace->{'action_traces'}})
                {
                    process_atrace($atrace, $tx);
                }
            }
        }
    }
    elsif( $msgtype == 1010 ) # CHRONICLE_MSGTYPE_BLOCK_COMPLETED
    {
        $blocks_counter++;
        $uncommitted_block = $data->{'block_num'};
        if( $uncommitted_block - $committed_block >= $commit_every or
            $uncommitted_block >= $endblock )
        {
            $committed_block = $uncommitted_block;

            my $gap = 0;
            {
                my ($year, $mon, $mday, $hour, $min, $sec, $msec) =
                    split(/[-:.T]/, $data->{'block_timestamp'});
                my $epoch = timegm_nocheck($sec, $min, $hour, $mday, $mon-1, $year);
                $gap = (time() - $epoch)/3600.0;
            }

            my $period = time() - $counter_start;
            printf STDERR ("blocks/s: %5.2f, actions/block: %5.2f, actions/s: %5.2f, gap: %6.2fh, ",
                           $blocks_counter/$period, $actions_counter/$blocks_counter, $actions_counter/$period,
                           $gap);
            $counter_start = time();
            $blocks_counter = 0;
            $actions_counter = 0;

            if( $uncommitted_block > $stored_block )
            {
                my $block_time = $data->{'block_timestamp'};
                $block_time =~ s/T/ /;
                $sth_upd_sync->execute($network, $uncommitted_block, $block_time, $uncommitted_block, $block_time);
                $dbh->commit();
                $stored_block = $uncommitted_block;
            }
            return $committed_block;
        }
    }

    return -1;
}


sub process_atrace
{
    my $atrace = shift;
    my $tx = shift;

    my $act = $atrace->{'act'};
    my $contract = $act->{'account'};
    my $receipt = $atrace->{'receipt'};

    if( $receipt->{'receiver'} eq $contract )
    {

        my $aname = $act->{'name'};
        my $data = $act->{'data'};

        if( ref($data) ne 'HASH' )
        {
            if( $contract ne 'eosio.null' )
            {
                $sth_add_failure->execute($receipt->{'global_sequence'}, $tx->{'block_num'},
                                          $tx->{'block_time'}, $tx->{'trx_id'}, $contract);
            }
            return;
        }

        if( $aname eq 'create' )
        {
            check_currency($contract, $data->{'maximum_supply'}, $data->{'issuer'});
        }
        elsif( ($aname eq 'transfer' or $aname eq 'issue') and
               defined($data->{'quantity'}) and
               defined($data->{'to'}) and length($data->{'to'}) <= 13 and
               ($aname eq 'issue' or (defined($data->{'from'}) and
                                      $data->{'to'} ne $data->{'from'} and
                                      length($data->{'from'}) <= 13)) )
        {
            my $r = check_currency($contract, $data->{'quantity'});
            if( defined($r) ) {
                my ($amount, $currency) = @{$r};

                my $seq = $receipt->{'global_sequence'};
                my $to = $data->{'to'};
                my $from = $data->{'from'};
                my $block_num = $tx->{'block_num'};
                my $block_time = $tx->{'block_time'};
                my $trx_id = $tx->{'trx_id'};

                $amount =~ s/\.//;
                my $debit = '-' . $amount;

                $actions_counter++;

                # book for recipient
                $sth_add_bal->execute($to, $contract, $currency,
                                         $amount, $block_num, $block_time, $trx_id,
                                         $amount, $block_num, $block_time, $trx_id);

                $sth_add_xfer->execute($seq, $block_num, $block_time, $trx_id,
                                       $contract, $currency, $to, $amount,
                                       $to, $contract, $currency,
                                       $from, $data->{'memo'});

                # book for sender
                if( defined($from) )
                {
                    $sth_sub_bal->execute($amount, $block_num, $block_time, $trx_id,
                                          $from, $contract, $currency);

                    $sth_add_xfer->execute($seq, $block_num, $block_time, $trx_id,
                                           $contract, $currency, $from, $debit,
                                           $from, $contract, $currency,
                                           $to, $data->{'memo'});
                }
            }
        }
        elsif( $aname eq 'retire' )
        {
            my $r = check_currency($contract, $data->{'quantity'});
            if( defined($r) ) {
                my ($amount, $currency) = @{$r};
                my $issuer = $known_issuer{$contract}{$currency};
                if( defined($issuer) )
                {
                    my $seq = $receipt->{'global_sequence'};
                    my $block_num = $tx->{'block_num'};
                    my $block_time = $tx->{'block_time'};
                    my $trx_id = $tx->{'trx_id'};

                    $amount =~ s/\.//;
                    my $debit = '-' . $amount;

                    $actions_counter++;

                    $sth_sub_bal->execute($amount, $block_num, $block_time, $trx_id,
                                          $issuer, $contract, $currency);

                    $sth_add_xfer->execute($seq, $block_num, $block_time, $trx_id,
                                           $contract, $currency, $issuer, $debit,
                                           $issuer, $contract, $currency,
                                           undef, $data->{'memo'});
                }
            }
        }
    }
}



sub check_currency
{
    my $contract = shift;
    my $quantity = shift;
    my $issuer = shift;

    my ($amount, $currency) = split(/\s+/, $quantity);
    if( defined($amount) and defined($currency) and
        $amount =~ /^[0-9.]+$/ and $currency =~ /^[A-Z]{1,7}$/ )
    {
        if( not $known_currency{$contract}{$currency} )
        {
            my $decimals = 0;
            my $pos = index($amount, '.');
            if( $pos > -1 )
            {
                $decimals = length($amount) - $pos - 1;
            }
            my $multiplier = 10**$decimals;

            $sth_add_currency->execute($contract, $currency, $decimals, $multiplier);
            $known_currency{$contract}{$currency} = 1;
        }

        if( defined($issuer) and not defined($known_issuer{$contract}{$currency}) )
        {
            $sth_set_currency_issuer->execute($issuer, $contract, $currency);
            $known_issuer{$contract}{$currency} = $issuer;
        }

        return [$amount, $currency];
    }

    return undef;
}
