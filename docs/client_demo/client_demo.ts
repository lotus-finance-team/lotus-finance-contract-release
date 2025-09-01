import { Transaction } from "@mysten/sui/transactions";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui/utils";
import { SuiObjectChangeCreated } from "@mysten/sui/client";
import { SuiPriceServiceConnection, SuiPythClient } from "@pythnetwork/pyth-sui-js";
import { coinWithBalance } from "@mysten/sui/transactions";
import { bcs } from '@mysten/sui/bcs';
import { config } from 'dotenv';
import * as consts from './consts';
import { keypair, client, getFirstCoinOfType, getSignerFromPK, executeTransaction, inspectTransaction, keypairDelegate } from './utils';
config();

// Pyth client
const connection = new SuiPriceServiceConnection("https://hermes-beta.pyth.network");

//// ====== GLOBAL VARIABLES ====== ////
let lotus_lp_farm_address = '0xfbf890f7d91b57c4b8aad1cab07a1cc3ab929fd07a62da877f9b46b42866206f';
let lotus_lp_farm_cap_address = '0xfeb41b84d84c7da53503350ac38dc1aaa89bf213837d1e46987ce13fa4b69500';
let incentivized_db_vault_address = '0x262bf24fc5aaa616679cace6f768a3eb93325c352fa5729b718ffdeb9867f4d2';
let incentivized_db_vault_creator_cap_address = '0xc039864b127db9bd9d63754aa0a5cbd65f2c7e14fa3612fa7c1ebc4931ad33b3';
let incentivized_db_vault_trade_cap_address = '0x098c15f276084391c80473e341a9cda66465fb4c22183e807663576914398f77';

// 1.1 Setup Oracle Aggregator
const setupOracleAggregator = async () => {
    console.log('Setup Oracle Aggregator');
    const tx = new Transaction();

    const setupToken = (tokenType: string, priceFeedId: string, tokenDecimal: number, coinConfig: number) => {
        const tokenNormalizedFeedId = priceFeedId.replace("0x", "");
        const tokenHexBytes = Array.from(Buffer.from(tokenNormalizedFeedId, 'hex'));
        tx.moveCall({
            target: `${consts.LOTUS_PACKAGE_ID}::oracle_ag::update_pyth_price_id`,
            arguments: [
                tx.object(consts.ORACLE_AGGREGATOR),
                tx.object(consts.ORACLE_AGGREGATOR_CAP),
                tx.pure.vector('u8', tokenHexBytes),
            ],
            typeArguments: [tokenType],
        });
        tx.moveCall({
            target: `${consts.LOTUS_PACKAGE_ID}::oracle_ag::update_coin_decimal`,
            arguments: [
                tx.object(consts.ORACLE_AGGREGATOR),
                tx.object(consts.ORACLE_AGGREGATOR_CAP),
                tx.pure.u8(tokenDecimal),
            ],
            typeArguments: [tokenType],
        });
        tx.moveCall({
            target: `${consts.LOTUS_PACKAGE_ID}::oracle_ag::update_coin_config`,
            arguments: [
                tx.object(consts.ORACLE_AGGREGATOR),
                tx.object(consts.ORACLE_AGGREGATOR_CAP),
                tx.pure.u64(coinConfig),
            ],
            typeArguments: [tokenType],
        });
    }

    setupToken(consts.COINS.SUI.type, consts.PYTH_FEEDS['SUI/USD'].address, 9, consts.CPYTH_PRICE);
    setupToken(consts.COINS.DEEP.type, consts.PYTH_FEEDS['DEEP/USD'].address, 6, consts.CPYTH_PRICE);
    setupToken(consts.COINS.USDC.type, consts.PYTH_FEEDS['USDC/USD'].address, 6, consts.CPYTH_PRICE);

    // Update Lotus Config to 1% performance fee
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_config::update_current_version`,
        arguments: [
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.LOTUS_CONFIG_CAP),
            tx.pure.u64(1), // Update to version 1
        ],
        typeArguments: [],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_config::update_performance_fee_bps`,
        arguments: [
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.LOTUS_CONFIG_CAP),
            tx.pure.u64(0),
        ],
        typeArguments: [],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_config::update_strategy_fee_bps`,
        arguments: [
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.LOTUS_CONFIG_CAP),
            tx.pure.u64(0),
        ],
        typeArguments: [],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_config::update_cold_down_ms`,
        arguments: [
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.LOTUS_CONFIG_CAP),
            tx.pure.u64(1000 * 0.1),
        ],
        typeArguments: [],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_config::update_max_deep_fee_bps`,
        arguments: [
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.LOTUS_CONFIG_CAP),
            tx.pure.u64(90), // 0.9%
        ],
        typeArguments: [],
    });

    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 1.2 Create LP Farm
const createLpFarm = async () => {
    console.log('Create LP Farm');
    const tx = new Transaction()
    const [farm, cap] = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::new`,
        arguments: [],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::add_allowed_deposit_asset`,
        arguments: [farm, cap],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.SUI.type],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::add_allowed_deposit_asset`,
        arguments: [farm, cap],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::add_allowed_db_pool`,
        arguments: [farm, cap, tx.object(consts.DB_POOLS.DEEP_SUI.address)],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.moveCall({
        target: '0x2::transfer::public_share_object',
        arguments: [farm],
        typeArguments: [`${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::LotusLPFarm<${consts.LP_TOKEN_TYPE}>`],
    });
    tx.transferObjects([cap], keypair.getPublicKey().toSuiAddress());
    tx.setGasBudget(100000000);
    const res = await executeTransaction(tx);

    const createdLotusLPFarm = res?.objectChanges?.find((change): change is SuiObjectChangeCreated => {
        return change.type === 'created' && change.objectType.includes('lotus_lp_farm::LotusLPFarm<');
    })?.objectId;
    lotus_lp_farm_address = createdLotusLPFarm ?? '';
    console.log(`\tFarm address: ${lotus_lp_farm_address}`);
    const createdLotusLPFarmCap = res?.objectChanges?.find((change): change is SuiObjectChangeCreated => {
        return change.type === 'created' && change.objectType.includes('lotus_lp_farm::LotusLPFarmCap');
    })?.objectId;
    lotus_lp_farm_cap_address = createdLotusLPFarmCap ?? '';
    console.log(`\tLotus LP Farm Cap address: ${lotus_lp_farm_cap_address}`);    
};

// 2.1 Add TD Farm
const addTDFarm = async () => {
    console.log('Add TD Farm');
    const tx = new Transaction();

    console.log("\tTD Farm Start time: ", Math.floor(Date.now() / 1000));
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::add_td_farm`,
        arguments: [
            tx.object(lotus_lp_farm_address), 
            tx.object(lotus_lp_farm_cap_address),
            tx.pure.u64(Math.floor(Date.now() / 1000)),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
};

// 2.2 Top up TD Farm
const topUpTDFarm = async () => {
    console.log('Top up TD Farm');
    const tx = new Transaction()
    const coin = coinWithBalance({
        type: consts.COINS.DEEP.type,
        balance: BigInt(100_000),
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::top_up_incentive_balance`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            coin,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 3. Create Incentivized DB Vault
// This operation is atomic. Should execute these in one PTB.
const createIncentivizedDBVault = async () => {
    console.log('Create Incentivized DB Vault');

    // Pyth client
    const priceUpdateData = await connection.getPriceFeedsUpdateData([consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['SUI/USD'].address]);
    const pyth_client = new SuiPythClient(client, consts.PYTH_STATE_ID, consts.WORMHOLE_STATE_ID);

    const tx = new Transaction();
    // CMD 0-5
    const priceInfoObjectIds = await pyth_client.updatePriceFeeds(tx, priceUpdateData, [consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['SUI/USD'].address]);

    // -- 3.1 Create Incentivized DB Vault
    const coin_base = coinWithBalance({
        type: consts.COINS.DEEP.type,
        balance: BigInt(1_000_000),
    });
    const coin_quote = coinWithBalance({
        type: consts.COINS.SUI.type,
        balance: BigInt(1_000_000_000),
    });
    // CMD 6
    const [vault, vault_creator_cap, vault_trade_cap, create_vault_ticket] = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::create_incentivized_db_vault`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            coin_base,
            coin_quote,
            tx.object(consts.ORACLE_AGGREGATOR),
            tx.object(priceInfoObjectIds[0]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    // CMD 7
    // Transfer vault_cap to the owner
    tx.transferObjects([vault_creator_cap], keypair.getPublicKey().toSuiAddress());
    //// NOTE!!!! Don't share the cap in production case! Here is only for differentiate the creator cap and trade cap.
    tx.moveCall({
        target: '0x2::transfer::public_share_object',
        arguments: [vault_trade_cap],
        typeArguments: [`${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::LotusDBVaultCap`],
    });
    // CMD 8
    // Add DBVault to TD Farm
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::add_incentivized_db_vault_to_td_farm_with_ticket`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            vault,
            create_vault_ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    // CMD 13
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::destroy_create_pool_ticket`,
        arguments: [tx.object(lotus_lp_farm_address), create_vault_ticket],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    // CMD 14
    tx.moveCall({
        target: '0x2::transfer::public_share_object',
        arguments: [vault],
        typeArguments: [`${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::LotusDBVault<${consts.LP_TOKEN_TYPE}>`],
    });


    tx.setGasBudget(100000000);
    const res = await executeTransaction(tx);

    const createdIncentivizedDBVault = res?.objectChanges?.find((change): change is SuiObjectChangeCreated => {
        return change.type === 'created' && change.objectType.includes('lotus_db_vault::LotusDBVault<');
    })?.objectId;
    incentivized_db_vault_address = createdIncentivizedDBVault ?? '';
    const createdIncentivizedDBVaultCreatorCap = res?.objectChanges?.find((change): change is SuiObjectChangeCreated => {
        return change.type === 'created' && change.objectType.includes('lotus_db_vault::LotusDBVaultCap') && typeof change.owner === 'object' &&
        'AddressOwner' in change.owner;
    })?.objectId;
    const createdIncentivizedDBVaultTradeCap = res?.objectChanges?.find((change): change is SuiObjectChangeCreated => {
        return change.type === 'created' && change.objectType.includes('lotus_db_vault::LotusDBVaultCap') && typeof change.owner === 'object' &&
        'Shared' in change.owner;
    })?.objectId;
    
    incentivized_db_vault_creator_cap_address = createdIncentivizedDBVaultCreatorCap ?? '';
    incentivized_db_vault_trade_cap_address = createdIncentivizedDBVaultTradeCap ?? '';
    console.log(`\tIncentivized DB Vault address: ${incentivized_db_vault_address}`);
    console.log(`\tIncentivized DB Vault Creator Cap address: ${incentivized_db_vault_creator_cap_address}`);
    console.log(`\tIncentivized DB Vault Trade Cap address: ${incentivized_db_vault_trade_cap_address}`);
};

// 3.3 Set unlock rate
const setUnlockRate = async () => {
    console.log('Set unlock rate');
    const tx = new Transaction();
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::set_farm_unlock_rate`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(lotus_lp_farm_cap_address),
            tx.pure.u64(10),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 4.1 Collect incentives
const collectIncentives = async () => {
    console.log('Collect incentives');
    const tx = new Transaction();
    // CMD 0
    const ticket = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::new_top_up_ticket`,
        arguments: [tx.object(incentivized_db_vault_address)],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    // CMD 1
    // For all TD pool, top up to TD Pool with `top_up_ticket`.
    // Different incentive tokens should all be top up.
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::top_up_to_td_pool`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    // CMD 2
    // Collect incentives
    const incentiveCoin = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_redeem_incentive`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            ticket,
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.transferObjects([incentiveCoin], keypair.getPublicKey().toSuiAddress());
    tx.setGasBudget(100000000);
    await executeTransaction(tx);

    // Inspect incentive amount
    const inspTx = new Transaction();
    inspTx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::get_incentive_value`,
        arguments: [inspTx.object(incentivized_db_vault_address)],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    const res = await inspectTransaction(keypair.getPublicKey().toSuiAddress(), inspTx);
    const returnValues = res?.results?.[0]?.returnValues ?? [];
    for (const returnValue of returnValues) {
        const numberArray: number[] = Array.isArray(returnValue) && Array.isArray(returnValue[0]) ? returnValue[0] : [];
        const returnValueParsed = bcs.u64().parse(new Uint8Array(numberArray));
        console.log(`- Incentive value: ${returnValueParsed}`);
    }
}

// 4.2 Update vault weight
const updateVaultWeight = async () => {
    console.log('Update vault weight');
    const tx = new Transaction();
    // Pyth client
    const priceFeedIds = [consts.PYTH_FEEDS['SUI/USD'].address, consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['USDC/USD'].address];
    const pyth_client = new SuiPythClient(client, consts.PYTH_STATE_ID, consts.WORMHOLE_STATE_ID);
    const priceUpdateData = await connection.getPriceFeedsUpdateData(priceFeedIds);
    // CMD 0-5
    const priceInfoObjectIds = await pyth_client.updatePriceFeeds(tx, priceUpdateData, priceFeedIds);
    const poolAddress = consts.DB_POOLS.DEEP_SUI.address;
    
    const update_vault_weight_ticket = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::create_update_vault_weight_ticket`,
        arguments: [tx.object(lotus_lp_farm_address)],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::update_vault_weight_with_ticket`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            tx.object(poolAddress),
            tx.object(priceInfoObjectIds[1]),
            tx.object(priceInfoObjectIds[0]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(consts.ORACLE_AGGREGATOR),
            update_vault_weight_ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::destroy_update_vault_weight_ticket`,
        arguments: [tx.object(lotus_lp_farm_address), update_vault_weight_ticket],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 5.1 Place Order
const placeOrder = async () => {
    console.log('Place Order');
    const poolAddress = consts.DB_POOLS.DEEP_SUI.address;
    const clientOrderId = 1;
    const orderType = 0;
    const selfMatchingOption = 0;
    const price = 0.001 * 1_000_000_000_000;     // 1 * QuoteScale / BaseScale * 1_000_000_000
    const quantity = 100 * 1_000_000; // 0.1 * BaseScale
    const isBid = true;
    const payWithDeep = true;
    const expireTimestamp = consts.MAX_TIMESTAMP;

    const tx = new Transaction();
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::place_limit_order`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(incentivized_db_vault_trade_cap_address),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            tx.pure.u64(clientOrderId),
            tx.pure.u8(orderType),
            tx.pure.u8(selfMatchingOption),
            tx.pure.u64(price),
            tx.pure.u64(quantity),
            tx.pure.bool(isBid),
            tx.pure.bool(payWithDeep),
            tx.pure.u64(expireTimestamp),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
};

// 5.2 Cancel Order
const cancelOrder = async () => {
    console.log('Cancel Order');
    
    // Get order id
    const inspTx = new Transaction();
    inspTx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::account_open_orders`,
        arguments: [inspTx.object(incentivized_db_vault_address), inspTx.object(consts.DB_POOLS.DEEP_SUI.address)],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    const inspRes = await inspectTransaction(keypair.getPublicKey().toSuiAddress(), inspTx);
    const returnValues = inspRes?.results?.[0]?.returnValues ?? [];
    for (const returnValue of returnValues) {
        const numberArray: number[] = Array.isArray(returnValue) && Array.isArray(returnValue[0]) ? returnValue[0] : [];
        const returnValueParsed = bcs.u128().parse(new Uint8Array(numberArray));
        console.log(`- Open order: ${returnValueParsed}`);
    
        const clientOrderId = returnValueParsed;
        const tx = new Transaction();
        tx.moveCall({
            target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::cancel_order`,
            arguments: [
                tx.object(incentivized_db_vault_address),
                tx.object(incentivized_db_vault_trade_cap_address),
                tx.object(consts.DB_POOLS.DEEP_SUI.address),
                tx.pure.u128(clientOrderId),
                tx.object(SUI_CLOCK_OBJECT_ID),
            ],
            typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
        });
        tx.setGasBudget(100000000);
        await executeTransaction(tx);
    }
}

// 5.2-alt Cancel All Order
const cancelAllOrders = async () => {
    console.log('Cancel All Order');
    const tx = new Transaction();
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::cancel_all_orders`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(incentivized_db_vault_trade_cap_address),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 5.3 Settle
const withdrawSettledAmounts = async () => {
    console.log('Withdraw Settled Amounts');
    const tx = new Transaction();
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::withdraw_settled_amounts`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 5.4 Redeem
const redeemAll = async () => {
    console.log('Redeem All');
    const tx = new Transaction();
    // Pyth client
    const priceFeedIds = [consts.PYTH_FEEDS['SUI/USD'].address, consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['USDC/USD'].address];
    const pyth_client = new SuiPythClient(client, consts.PYTH_STATE_ID, consts.WORMHOLE_STATE_ID);
    const priceUpdateData = await connection.getPriceFeedsUpdateData(priceFeedIds);
    // CMD 0-5
    const priceInfoObjectIds = await pyth_client.updatePriceFeeds(tx, priceUpdateData, priceFeedIds);
    const poolAddress = consts.DB_POOLS.DEEP_SUI.address;

    // Collect incentives
    // lotus_db_vault::new_top_up_ticket
    // lotus_lp_farm::top_up_to_td_pool
    // lotus_lp_farm::collect_incentive_rewards_to_vault
    // lotus_lp_farm::remove_farm_key_from_td_farm
    // lotus_db_vault::redeem_incentive
    const top_up_ticket = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::new_top_up_ticket`,
        arguments: [tx.object(incentivized_db_vault_address)],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::top_up_to_td_pool`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            top_up_ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    const incentiveCoin = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_redeem_incentive`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            top_up_ticket,
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.transferObjects([incentiveCoin], keypair.getPublicKey().toSuiAddress());
    const [coinBasePooling, coinQuotePooling] = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_withdraw`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            tx.object(priceInfoObjectIds[0]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(consts.ORACLE_AGGREGATOR),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.transferObjects([coinBasePooling, coinQuotePooling], keypair.getPublicKey().toSuiAddress());
    
    // Redeem assets
    const ticket = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::close_vault`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            tx.object(incentivized_db_vault_creator_cap_address),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::remove_farm_key_from_td_farm`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::destroy_close_vault_ticket`,
        arguments: [tx.object(lotus_lp_farm_address), ticket],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });

    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

// 6. Pooling walkthrough
// 6.1 Pooling deposit
const pooling_deposit = async () => {
    console.log('Pooling Walkthrough');
    const tx = new Transaction();
    // Pyth client
    const priceFeedIds = [consts.PYTH_FEEDS['SUI/USD'].address, consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['USDC/USD'].address];
    const pyth_client = new SuiPythClient(client, consts.PYTH_STATE_ID, consts.WORMHOLE_STATE_ID);
    const priceUpdateData = await connection.getPriceFeedsUpdateData(priceFeedIds);
    // CMD 0-5
    const priceInfoObjectIds = await pyth_client.updatePriceFeeds(tx, priceUpdateData, priceFeedIds);
    const poolAddress = consts.DB_POOLS.DEEP_SUI.address;

    const coin_base = coinWithBalance({
        type: consts.COINS.DEEP.type,
        balance: BigInt(1_000_000),
    });
    const coin_quote = coinWithBalance({
        type: consts.COINS.SUI.type,
        balance: BigInt(1_000_000_000),
    });
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_deposit`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.LOTUS_CONFIG),
            coin_base,
            coin_quote,
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            tx.object(priceInfoObjectIds[0]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(consts.ORACLE_AGGREGATOR),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });

    tx.setGasBudget(100000000);
    await executeTransaction(tx, keypairDelegate);
}

// 6.2 Pooling withdraw
const pooling_withdraw = async () => {
    console.log('Pooling Withdraw');
    const tx = new Transaction();
    // Pyth client
    const priceFeedIds = [consts.PYTH_FEEDS['SUI/USD'].address, consts.PYTH_FEEDS['DEEP/USD'].address, consts.PYTH_FEEDS['USDC/USD'].address];
    const pyth_client = new SuiPythClient(client, consts.PYTH_STATE_ID, consts.WORMHOLE_STATE_ID);
    const priceUpdateData = await connection.getPriceFeedsUpdateData(priceFeedIds);
    // CMD 0-5
    const priceInfoObjectIds = await pyth_client.updatePriceFeeds(tx, priceUpdateData, priceFeedIds);
    const poolAddress = consts.DB_POOLS.DEEP_SUI.address;

    // CMD 6
    const top_up_ticket = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::new_top_up_ticket`,
        arguments: [tx.object(incentivized_db_vault_address)],
        typeArguments: [consts.LP_TOKEN_TYPE],
    });
    // CMD 7
    tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_lp_farm::top_up_to_td_pool`,
        arguments: [
            tx.object(lotus_lp_farm_address),
            tx.object(incentivized_db_vault_address),
            top_up_ticket,
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    // CMD 8
    // Collect incentives
    const incentiveCoin = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_redeem_incentive`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            top_up_ticket,
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    tx.transferObjects([incentiveCoin], keypairDelegate.getPublicKey().toSuiAddress());
    // CMD 9
    // Withdraw assets
    const [coinBase, coinQuote] = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::pooling_withdraw`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.LOTUS_CONFIG),
            tx.object(consts.DB_POOLS.DEEP_SUI.address),
            tx.object(priceInfoObjectIds[0]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(priceInfoObjectIds[1]),
            tx.object(consts.ORACLE_AGGREGATOR),
            tx.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type, consts.COINS.SUI.type],
    });
    tx.transferObjects([coinBase, coinQuote], keypairDelegate.getPublicKey().toSuiAddress());

    tx.setGasBudget(100000000);
    await executeTransaction(tx, keypairDelegate);
}

// 7. Performance Fee and Strategy Fee
const collectFees = async () => {
    console.log('Collect Fees');
    const tx = new Transaction();
    const performanceFeeDeep = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::withdraw_collected_performance_fees`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.LOTUS_CONFIG_CAP),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    const performanceFeeSui = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::withdraw_collected_performance_fees`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(consts.LOTUS_CONFIG_CAP),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.SUI.type],
    });
    const strategyFeeDeep = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::withdraw_collected_strategy_fees`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(incentivized_db_vault_creator_cap_address),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.DEEP.type],
    });
    const strategyFeeSui = tx.moveCall({
        target: `${consts.LOTUS_PACKAGE_ID}::lotus_db_vault::withdraw_collected_strategy_fees`,
        arguments: [
            tx.object(incentivized_db_vault_address),
            tx.object(incentivized_db_vault_creator_cap_address),
        ],
        typeArguments: [consts.LP_TOKEN_TYPE, consts.COINS.SUI.type],
    });
    tx.transferObjects([performanceFeeDeep, performanceFeeSui, strategyFeeDeep, strategyFeeSui], keypair.getPublicKey().toSuiAddress());
    tx.setGasBudget(100000000);
    await executeTransaction(tx);
}

const main = async () => {


    // await adhocInspect(); return;

    //// ====== DEMO Case ====== ////
    //
    // Farm:
    // - LotusLPFarm<LP_TOKEN>
    //   - allowed_deposit_assets: [SUI]
    //   - td_farms: [<DEEP>]
    //
    // Vault:
    // - LotusDBVault<LP_TOKEN>
    //   - pool: DEEP_SUI
    //
    // Params:
    // - Incentive: 1 DEEP
    // - Unlock rate: 10 Native DEEP / second
    // - Vault deposit: 10 SUI

    // 1.1 Setup Oracle Aggregator
    await setupOracleAggregator();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 1.2 Create LP Farm
    await createLpFarm();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 2. Incentives
    // 2.1 Add TD Farm
    await addTDFarm();
    await new Promise(resolve => setTimeout(resolve, 5000));

    // 2.2 Top up TD Farm
    await topUpTDFarm();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 3. Vault
    // 3.1 Create Incentivized DB Vault
    // 3.2 Add Incentivized DB Vault to TD Farm
    await createIncentivizedDBVault();
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    // 3.3 Set unlock rate
    await setUnlockRate();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 3.4 Mint lotus_trade_cap
    // await mintLotusTradeCap();
    // await new Promise(resolve => setTimeout(resolve, 1000));

    // 4. Incentives
    // 4.1 Collect incentives
    await collectIncentives();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // // 5. DB interaction
    // // 5.1 Place Order
    await placeOrder();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // // // 5.2 Cancel Order
    await cancelOrder();
    await new Promise(resolve => setTimeout(resolve, 1000));
    // // 5.2-alt Cancel All Order
    await cancelAllOrders();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 4.2 Update vault weight
    await updateVaultWeight();
    await new Promise(resolve => setTimeout(resolve, 1000));
    

    // // 5.3 Settle
    // await withdrawSettledAmounts();
    // await new Promise(resolve => setTimeout(resolve, 1000));

    // 6. Pooling walkthrough
    await pooling_deposit();
    await new Promise(resolve => setTimeout(resolve, 1000));
    await pooling_withdraw();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 5.4 Redeem
    await redeemAll();
    await new Promise(resolve => setTimeout(resolve, 1000));

    // 7. Performance Fee and Strategy Fee
    await collectFees();
    await new Promise(resolve => setTimeout(resolve, 1000));
};

main().catch(console.error);