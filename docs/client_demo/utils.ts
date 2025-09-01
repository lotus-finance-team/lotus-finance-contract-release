import { Transaction } from "@mysten/sui/transactions";
import { CoinStruct, DevInspectResults, getFullnodeUrl, SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { config } from 'dotenv';
config();

export const client = new SuiClient({
    url: getFullnodeUrl("testnet"),
});

// Function to get coins of a specific type
export async function getFirstCoinOfType({
    coinType,
    client,
    owner,
}: {
    coinType: string;
    client: SuiClient;
    owner: string;
}): Promise<CoinStruct | null> {
    let cursor: string | null | undefined = null;

    while (true) {
        const { data, hasNextPage, nextCursor } = await client.getCoins({ owner, coinType, cursor });

        if (data.length > 0) {
            // Return the first coin found
            return data[0];
        }

        if (!hasNextPage) {
            break;
        }

        cursor = nextCursor;
    }

    // Return null if no coin of the specified type is found
    return null;
}

export const getSignerFromPK = (privateKey: string): Ed25519Keypair => {
    const { schema, secretKey } = decodeSuiPrivateKey(privateKey);
    if (schema === 'ED25519') return Ed25519Keypair.fromSecretKey(secretKey);
    throw new Error(`Unsupported schema: ${schema}`);
};

export const privateKey = process.env.PRIVATE_KEY as string;
export const privateKeyDelegate = process.env.PRIVATE_KEY_DELEGATE as string;
export const keypair = getSignerFromPK(privateKey);
export const keypairDelegate = getSignerFromPK(privateKeyDelegate);


export const executeTransaction = async (tx: Transaction, keypairOverride?: Ed25519Keypair) => {
    try {
        const signer = keypairOverride || keypair;
        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer,
            options: {
                showEffects: true,
                showObjectChanges: true,
            },
        });
        // console.log(JSON.stringify(result, null, 2));
        const status = result.effects?.status?.status;
        const error = result.effects?.status?.error;
        const color = status === "success" ? "\x1b[32m" : "\x1b[31m";
        if (error) {
            console.log(`\tTransaction result:${color} ${status}, Error: ${error}\x1b[0m, Digest: https://testnet.suivision.xyz/txblock/${result.digest}`);
        } else {
            console.log(`\tTransaction result:${color} ${status}\x1b[0m, Digest: https://testnet.suivision.xyz/txblock/${result.digest}`);
        }
        return result;
    } catch (error) {
        console.error("\tTransaction execution failed:", error);
    }
};

export const inspectTransaction = async (pub_key: string, tx: Transaction): Promise<DevInspectResults> => {
    try {
        const result = await client.devInspectTransactionBlock({sender: pub_key, transactionBlock: tx});
        console.log(`Transaction inspection result: ${JSON.stringify(result.effects?.status)}`);
        return result;
    } catch (error) {
        console.error("Transaction inspection failed:", error);
        throw error;
    }
};

