NETWORK=$1

if [ x${NETWORK} = x ]; then echo "Network required" 1>&2; exit 1; fi


mysql --database=eosio_token_accounting --execute='ALTER TABLE '${NETWORK}'_CURRENCIES ADD COLUMN issuer VARCHAR(13) NULL'

if [ $? -eq 0 ]; then echo "Done"; else echo "Errors encountered"; fi

                             
