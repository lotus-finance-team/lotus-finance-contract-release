/*
This module is for Lotus Deepbook Vault.
For the time being, it only supports 
- **single Pool** in Deepbook
tokens. On deposit the vault will add stake to Vault and share in the LotusFarm on TVL basis.
*/
module lotus_finance::lotus_db_vault {
    use std::debug;
    use std::type_name::{Self, TypeName};
    use std::string::{Self as STD_STRING};
    use sui::bag::{Self, Bag};
    use sui::vec_set::{Self, VecSet};
    use sui::vec_map::{Self, VecMap};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use sui::event;
    use deepbook::balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap};
    use deepbook::account::{Account};
    use deepbook::pool::{Self as db_pool, Pool as DBPool};
    use deepbook::order::{Order};
    use token::deep::DEEP;
    use token_distribution::accumulation_distributor::{Self as acc, AccumulationDistributor, Position};
    use token_distribution::farm::{Self, Farm as TDFarm, AdminCap as TDFarmAdminCap, FarmMemberKey, MemberWithdrawAllTicket};
    use pyth::price_info::PriceInfoObject;
    use lotus_finance::consts::{Self};
    use lotus_finance::lotus_math::{mul_div_u64, scale_from_float, scale_to_float};
    use lotus_finance::lotus_config::{Self, LotusConfig, LotusConfigCap};
    use lotus_finance::oracle_ag::{OracleAggregator, assert_price_object_type};
    use sui::table::{Self, Table};
    use std::string::{Self, String, utf8};
    use std::u256;
    use std::u64;

    // Lotus DB Vault struct.
    public struct LotusDBVault<phantom LP> has key, store {
        id: UID,
        // --- Token Distribution ---//
        incentive_acc: AccumulationDistributor,
        farm_key: FarmMemberKey,
        // --- Strategy Params ---//
        strategy_params: Table<String, u64>, // Strategy params for the vault. Key type: ID
        // --- Pooling ---//
        user_positions: VecMap<address, Position>,       // User shares in the vault. Key type: ID
        user_cost: VecMap<address, u64>,         // User cost in the vault. Key type: ID
        user_last_interaction: VecMap<address, u64>, // User last interaction timestamp. Key type: ID
        // --- Deepbook ---//
        allowed_pool: ID,
        balance_manager: BalanceManager,    // DB BM
        trade_cap: TradeCap,                // DB BM Trade Cap
        deposit_cap: DepositCap,            // DB BM Deposit Cap
        withdraw_cap: WithdrawCap,          // DB BM Withdraw Cap
        // --- Operational ---//
        free_balances: Bag,                 // Free balances for allocation / withdraw
        collected_performance_fees: Bag,    // Performance fee balance Bag. Might have multiple coins
        collected_strategy_fees: Bag,       // Strategy fee balance Bag. Might have multiple coins
        staked_deep_amount: u64,            // Staked DEEP amount
    }

    //// ====== Permission Flags ====== ////
    // Permission Access Flags 
    const PMasterAccess: u64    = 1 << 0;
    const PAssetAccess: u64     = 1 << 1;
    const PStrategyAccess: u64  = 1 << 2;
    const PTradeAccess: u64     = 1 << 3;
    const PCreatorAccess: u64   = 1 << 4;

    public fun GET_P_MASTER_ACCESS(): u64 { PMasterAccess }
    public fun GET_P_ASSET_ACCESS(): u64 { PAssetAccess }
    public fun GET_P_STRATEGY_ACCESS(): u64 { PStrategyAccess }
    public fun GET_P_TRADE_ACCESS(): u64 { PTradeAccess }
    public fun GET_P_CREATOR_ACCESS(): u64 { PCreatorAccess }

    //// ====== Errors ====== ////
    const EInvalidAccess: u64 = 0;
    const EUnauthorizedDBPool: u64 = 1;
    const EOperationColdDown: u64 = 2;
    const ETooMuchDeepFee: u64 = 3;
    const EInvalidDeposit: u64 = 4;
    const EInvalidWithdraw: u64 = 5;
    const EInvalidVaultStatus: u64 = 6;
    const EInvalidStrategyParams: u64 = 7;
    const EImbalanceDeposit: u64 = 8;
    const EOverflow: u64 = 9;
    

    //// ====== Structs ====== ////
    public struct LotusDBVaultCap has key, store {
        id: UID,
        vault_id: ID,
        access_flag: u64,
    }

    //// ====== Events ====== ////
    public struct ActivateBotEvent has copy, drop {
        vault_id: ID,
        trade_cap_id: ID,
        balance_manager_id: ID,
    }

    public struct PoolingDepositEvent has copy, drop {
        vault_id: ID,
        user_address: address,
        base_amount: u64,
        quote_amount: u64,
        deep_amount: u64,
    }

    public struct PoolingWithdrawEvent has copy, drop {
        vault_id: ID,
        user_address: address,
        base_amount: u64,
        quote_amount: u64,
        deep_amount: u64,
        user_shares: u64,
        user_cost: u64,
        vault_total_shares: u64,
        if_update_order: bool,
    }

    public struct RedeemAllFromVaultEvent has copy, drop {
        vault_id: ID,
        base_amount: u64,
        quote_amount: u64,
        deep_amount: u64,
    }

    public struct RedeemIncentivesEvent has copy, drop {
        vault_id: ID,
        incentive_type: TypeName,
        incentive_value: u64,
    }

    public struct ClaimRebateEvent has copy, drop {
        vault_id: ID,
        base_amount: u64,
        quote_amount: u64,
        deep_amount: u64,
    }

    public struct UpdateStrategyParamsEvent has copy, drop {
        vault_id: ID,
        key: String,
        value: u64,
    }

    public struct TopUpTDPoolEvent has copy, drop {
        vault_id: ID,
        td_farm_id: ID,
        coin_type: TypeName,
    }

    public struct DBStakeEvent has copy, drop {
        vault_id: ID,
        pool_id: ID,
        balance_manager_id: ID,
        epoch: u64,
        amount: u64,
        stake: bool,
    }

    public(package) fun new<LP>(allowed_pool_id: ID, ctx: &mut TxContext): LotusDBVault<LP> {
        let incentive_acc = acc::create(ctx);
        let mut balance_manager = balance_manager::new(ctx);
        let trade_cap = balance_manager.mint_trade_cap(ctx);
        let deposit_cap = balance_manager.mint_deposit_cap(ctx);
        let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);
        let vault = LotusDBVault<LP> {
            id: object::new(ctx),
            incentive_acc: incentive_acc,
            farm_key: farm::create_member_key(ctx),
            strategy_params: table::new(ctx),
            user_positions: vec_map::empty(),
            user_cost: vec_map::empty(),
            user_last_interaction: vec_map::empty(),
            allowed_pool: allowed_pool_id,
            balance_manager: balance_manager,
            trade_cap: trade_cap,
            deposit_cap: deposit_cap,
            withdraw_cap: withdraw_cap,
            free_balances: bag::new(ctx),
            collected_performance_fees: bag::new(ctx),
            collected_strategy_fees: bag::new(ctx),
            staked_deep_amount: 0,
        };
        vault
    }

    public(package) fun new_for_pooling<LP>(allowed_pool_id: ID, user_cost: u64, clock: &Clock, ctx: &mut TxContext): (LotusDBVault<LP>, LotusDBVaultCap, LotusDBVaultCap) {
        let mut vault = new<LP>(allowed_pool_id, ctx);
        let vault_creator_cap = LotusDBVaultCap {
            id: object::new(ctx),
            vault_id: object::id(&vault),
            access_flag: PCreatorAccess,
        };
        let vault_trade_cap = LotusDBVaultCap {
            id: object::new(ctx),
            vault_id: object::id(&vault),
            access_flag: PTradeAccess,
        };
        let user_position = vault.incentive_acc.deposit_shares_new(user_cost);
        vault.user_positions.insert(ctx.sender(), user_position);
        vault.user_cost.insert(ctx.sender(), user_cost);
        (vault, vault_creator_cap, vault_trade_cap)
    }

    // --- LotusLPVault Operations --- //
    // Mint cap with permission access flag
    // Only master can mint cap
    // Deprecated in Pooling feature
    #[test_only]
    public fun mint_cap<LP>(self: &LotusDBVault<LP>, cap: &LotusDBVaultCap, access_flag: u64, ctx: &mut TxContext): LotusDBVaultCap {
        // Check if provided cap has master access
        assert_vault_cap_access(self, cap, PMasterAccess);
        // Can't mint cap with master access
        assert!(access_flag & PMasterAccess == 0, EInvalidAccess);
        // Mint cap with provided access flag
        let minted_cap = LotusDBVaultCap {
            id: object::new(ctx),
            vault_id: object::id(self),
            access_flag: access_flag,
        };
        minted_cap
    }

    #[test_only]
    public fun mint_lotus_trade_cap<LP>(self: &LotusDBVault<LP>, cap: &LotusDBVaultCap, ctx: &mut TxContext): LotusDBVaultCap {
        self.assert_vault_cap_access(cap, PMasterAccess);
        self.mint_cap<LP>(cap, PTradeAccess, ctx)
    }

    public fun mint_lotus_vault_cap_with_config_cap<LP>(
        self: &LotusDBVault<LP>,
        lotus_config_cap: &LotusConfigCap,
        ctx: &mut TxContext,
    ): LotusDBVaultCap {
        let minted_cap = LotusDBVaultCap {
            id: object::new(ctx),
            vault_id: object::id(self),
            access_flag: PMasterAccess,
        };
        minted_cap
    }

    // --- Deepbook Operations -- //
    // Deposit coin, don't use this in normal lifecycle.
    public(package) fun deposit<T, LP>(
        self: &mut LotusDBVault<LP>,
        to_deposit: Coin<T>,
        ctx: &TxContext,
    ) {
        self.balance_manager.deposit_with_cap(&self.deposit_cap, to_deposit, ctx);
    }

    // Stake DEEP for rebate
    public fun stake<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        db_pool: &mut DBPool<Base, Quote>,
        to_stake: Coin<DEEP>,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, db_pool);
        assert_vault_cap_access(self, cap, PCreatorAccess);
        let amount = to_stake.value();
        self.staked_deep_amount = self.staked_deep_amount + amount;
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        self.balance_manager.deposit_with_cap(&self.deposit_cap, to_stake, ctx);
        db_pool.stake(&mut self.balance_manager, &trade_proof, amount, ctx);

        // Emit event
        event::emit(DBStakeEvent {
            vault_id: object::id(self),
            pool_id: object::id(db_pool),
            balance_manager_id: object::id(&self.balance_manager),
            epoch: ctx.epoch(),
            amount,
            stake: true,
        });
    }

    // Unstake DEEP and withdraw, return the coin.
    public fun unstake<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        db_pool: &mut DBPool<Base, Quote>,
        ctx: &mut TxContext,
    ): Coin<DEEP> {
        assert_db_pool(self, db_pool);
        assert_vault_cap_access(self, cap, PCreatorAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        db_pool.unstake(&mut self.balance_manager, &trade_proof, ctx);
        let coin = self.balance_manager.withdraw<DEEP>(self.staked_deep_amount, ctx);
        self.staked_deep_amount = 0;

        // Emit event
        event::emit(DBStakeEvent {
            vault_id: object::id(self),
            pool_id: object::id(db_pool),
            balance_manager_id: object::id(&self.balance_manager),
            epoch: ctx.epoch(),
            amount: coin.value(),
            stake: false,
        });

        coin
    }

    #[test_only]
    public fun redeem_all_token_base_quote_deep<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        lotus_config: &LotusConfig,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_ag: &OracleAggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>, Coin<DEEP>) {
        lotus_config::assert_protocol_status_ok(lotus_config);
        lotus_config.assert_current_version();
        assert_db_pool(self, pool);
        // assert_vault_cap_access(self, cap, PAssetAccess);
        assert_price_object_type<Base>(oracle_ag, base_price_info_object);
        assert_price_object_type<Quote>(oracle_ag, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_ag, deep_price_info_object);

        let usd_value = self.get_total_usd_value(pool, base_price_info_object, quote_price_info_object, deep_price_info_object, oracle_ag, clock);
        let mut base = self.balance_manager.withdraw_all<Base>(ctx);
        let mut quote = self.balance_manager.withdraw_all<Quote>(ctx);
        let deep = self.balance_manager.withdraw_all<DEEP>(ctx);
        let creator_cost = self.user_cost[&ctx.sender()];
        if (usd_value > creator_cost) {
            // performance fee ratio = (usd_value - self.deposit_cost) / self.deposit_cost * lotus_config.performance_fee_bps / 10000
            let performance_fee_accrue_bps = lotus_config.get_performance_fee_bps() * (usd_value - creator_cost) / usd_value;
            let performance_fee_base_amount = base.value() * performance_fee_accrue_bps / 10000;
            let performance_fee_quote_amount = quote.value() * performance_fee_accrue_bps / 10000;
            let strategy_fee_accrue_bps = lotus_config.get_strategy_fee_bps() * (usd_value - creator_cost) / usd_value;
            let strategy_fee_base_amount = base.value() * strategy_fee_accrue_bps / 10000;
            let strategy_fee_quote_amount = quote.value() * strategy_fee_accrue_bps / 10000;
            if (self.collected_performance_fees.contains(type_name::get<Base>().into_string())) {
                let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_performance_fees[type_name::get<Base>().into_string()];
                base_fee_balance.join(coin::split(&mut base, performance_fee_base_amount, ctx).into_balance());
                let mut strategy_fee_balance: &mut Balance<Base> = &mut self.collected_strategy_fees[type_name::get<Base>().into_string()];
                strategy_fee_balance.join(coin::split(&mut base, strategy_fee_base_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Base>().into_string(), coin::split(&mut base, performance_fee_base_amount, ctx).into_balance());
                self.collected_strategy_fees.add(type_name::get<Base>().into_string(), coin::split(&mut base, strategy_fee_base_amount, ctx).into_balance());
            };
            if (self.collected_performance_fees.contains(type_name::get<Quote>().into_string())) {
                let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_performance_fees[type_name::get<Quote>().into_string()];
                quote_fee_balance.join(coin::split(&mut quote, performance_fee_quote_amount, ctx).into_balance());
                let mut strategy_fee_balance: &mut Balance<Quote> = &mut self.collected_strategy_fees[type_name::get<Quote>().into_string()];
                strategy_fee_balance.join(coin::split(&mut quote, strategy_fee_quote_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut quote, performance_fee_quote_amount, ctx).into_balance());
            };
            debug::print(&performance_fee_accrue_bps);
            debug::print(&performance_fee_base_amount);
        };


        debug::print(&base.value());
        // Emit event
        event::emit(RedeemAllFromVaultEvent {
            vault_id: object::id(self),
            base_amount: base.value(),
            quote_amount: quote.value(),
            deep_amount: deep.value(),
        });
        // Balance manager will verify the owner is the sender
        (base, quote, deep)
    }

    // Permissionless
    public fun withdraw_settled_amounts<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        pool: &mut DBPool<Base, Quote>,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.withdraw_settled_amounts(&mut self.balance_manager, &trade_proof);
    }

    public fun place_limit_order<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.place_limit_order(
            &mut self.balance_manager,
            &trade_proof,
            client_order_id,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            clock,
            ctx
        );
    }

    public fun buy_deep_fee<LP, Base, Quote, T>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        lotus_config: &LotusConfig,
        pool: &mut DBPool<Base, Quote>,
        deep_pool: &mut DBPool<DEEP, T>,
        deep_amount: u64,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_aggregator: &OracleAggregator,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        lotus_config.assert_current_version();
        assert!(type_name::get<Base>() != type_name::get<DEEP>(), EInvalidAccess);
        assert!(type_name::get<Quote>() != type_name::get<DEEP>(), EInvalidAccess);
        assert!(type_name::get<T>() == type_name::get<Base>() || type_name::get<T>() == type_name::get<Quote>(), EInvalidAccess);
        assert_price_object_type<Base>(oracle_aggregator, base_price_info_object);
        assert_price_object_type<Quote>(oracle_aggregator, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_aggregator, deep_price_info_object);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let vault_usd_value = self.get_total_usd_value(pool, base_price_info_object, quote_price_info_object, deep_price_info_object, oracle_aggregator, clock);
        let deep_amount_after = deep_amount + self.balance_manager.balance<DEEP>();
        let deep_usd_value_after = oracle_aggregator.calc_usd_value<DEEP>(deep_price_info_object, deep_amount_after, clock);
        assert!(vault_usd_value * lotus_config.get_max_deep_fee_bps() / 10_000 > deep_usd_value_after, ETooMuchDeepFee);
        assert_db_pool(self, pool);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        deep_pool.place_market_order(
            &mut self.balance_manager,
            &trade_proof,
            1000, 
            0, 
            deep_amount, 
            true, 
            true,
            clock,
            ctx
        );
    }

    public fun sell_deep_fee<LP, Base, Quote, T>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        deep_pool: &mut DBPool<DEEP, T>,
        deep_amount: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(type_name::get<Base>() != type_name::get<DEEP>(), EInvalidAccess);
        assert!(type_name::get<Quote>() != type_name::get<DEEP>(), EInvalidAccess);
        assert!(type_name::get<T>() == type_name::get<Base>() || type_name::get<T>() == type_name::get<Quote>(), EInvalidAccess);
        assert_vault_cap_access(self, cap, PTradeAccess);
        assert_db_pool(self, pool);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        deep_pool.place_market_order(
            &mut self.balance_manager,
            &trade_proof,
            1000, 
            0, 
            deep_amount, 
            false, 
            true,
            clock,
            ctx
        );
    }

    public fun place_market_order<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.place_market_order(
            &mut self.balance_manager,
            &trade_proof,
            client_order_id,
            self_matching_option,
            quantity,
            is_bid,
            pay_with_deep,
            clock,
            ctx
        );
    }

    public fun cancel_order<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        order_id: u128,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.cancel_order(&mut self.balance_manager, &trade_proof, order_id, clock, ctx);
    }

    public fun cancel_orders<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        order_ids: vector<u128>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.cancel_orders(&mut self.balance_manager, &trade_proof, order_ids, clock, ctx);
    }

    public fun cancel_all_orders<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        cap: &LotusDBVaultCap,
        pool: &mut DBPool<Base, Quote>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_vault_cap_access(self, cap, PTradeAccess);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        pool.cancel_all_orders(&mut self.balance_manager, &trade_proof, clock, ctx);
    }

    public fun claim_rebates_permissionless<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        pool: &mut DBPool<Base, Quote>,
        ctx: &mut TxContext,        
    ) {
        assert_db_pool(self, pool);
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        let base_amount_0 = self.get_total_balance<LP, Base, Base, Quote>(pool);
        let quote_amount_0 = self.get_total_balance<LP, Quote, Base, Quote>(pool);
        let deep_amount_0 = self.get_total_balance<LP, DEEP, Base, Quote>(pool);
        pool.claim_rebates(&mut self.balance_manager, &trade_proof, ctx);
        let base_amount_1 = self.get_total_balance<LP, Base, Base, Quote>(pool);
        let quote_amount_1 = self.get_total_balance<LP, Quote, Base, Quote>(pool);
        let deep_amount_1 = self.get_total_balance<LP, DEEP, Base, Quote>(pool);
        // Withdraw coins into self.incentive_acc
        pool.withdraw_settled_amounts<Base, Quote>(&mut self.balance_manager, &trade_proof);
        if (base_amount_1 > base_amount_0) {
            let base_coin = self.balance_manager.withdraw_with_cap<Base>(&self.withdraw_cap, base_amount_1 - base_amount_0, ctx);
            self.incentive_acc.top_up(base_coin.into_balance());
        };
        if (quote_amount_1 > quote_amount_0) {
            let quote_coin = self.balance_manager.withdraw_with_cap<Quote>(&self.withdraw_cap, quote_amount_1 - quote_amount_0, ctx);
            self.incentive_acc.top_up(quote_coin.into_balance());
        };
        if (type_name::get<Base>() != type_name::get<DEEP>() && type_name::get<Quote>() != type_name::get<DEEP>()) {
            if (deep_amount_1 > deep_amount_0) {
                let deep_coin = self.balance_manager.withdraw_with_cap<DEEP>(&self.withdraw_cap, deep_amount_1 - deep_amount_0, ctx);
                self.incentive_acc.top_up(deep_coin.into_balance());
            }
        };

        // Base and Quote are not DEEP. Otherwise there's no fee nor rebate.
        event::emit(ClaimRebateEvent {
            vault_id: object::id(self),
            base_amount: base_amount_1 - base_amount_0,
            quote_amount: quote_amount_1 - quote_amount_0,
            deep_amount: deep_amount_1 - deep_amount_0,
        });
    }

    #[test_only]
    public fun claim_rebates_test<LP, Base, Quote, T>(
        self: &mut LotusDBVault<LP>,
        pool: &mut DBPool<Base, Quote>,
        test_coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        self.incentive_acc.top_up(test_coin.into_balance());
    }
    
    // --- Token Distribution --- //
    public struct TopUpTicket {
        withdraw_all_ticket: MemberWithdrawAllTicket
    }

    fun destroy_top_up_ticket_with_farm_key(farm_key: &mut FarmMemberKey, ticket: TopUpTicket) {
        let TopUpTicket { withdraw_all_ticket } = ticket;
        farm::destroy_withdraw_all_ticket(withdraw_all_ticket, farm_key);
    }
    fun top_up_with_acc<T>(
        farm: &mut TDFarm<T>, acc: &mut AccumulationDistributor, ticket: &mut TopUpTicket, clock: &Clock
    ) {
        let balance = farm::member_withdraw_all_with_ticket(farm, &mut ticket.withdraw_all_ticket, clock);
        acc::top_up(acc, balance);
    }

    fun new_top_up_ticket_with_farm_key(farm_key: &mut FarmMemberKey): TopUpTicket {
        TopUpTicket {
            withdraw_all_ticket: farm::new_withdraw_all_ticket(farm_key)
        }
    }

    // Add to TDFarm
    public fun add_to_td_farm<LP, Incentive>(
        self: &mut LotusDBVault<LP>,
        td_farm: &mut TDFarm<Incentive>,
        td_farm_admin_cap: &TDFarmAdminCap,
        weight: u32,
        clock: &Clock,
    ) {
        farm::add_member(td_farm_admin_cap, td_farm, &mut self.farm_key, weight, clock);
    }

    public fun new_top_up_ticket<LP>(self: &mut LotusDBVault<LP>): TopUpTicket {
        new_top_up_ticket_with_farm_key(&mut self.farm_key)
    }

    //// Destroy top_up_ticket is called in deposit functions. Skip here
    // public fun destroy_top_up_ticket<LP>(self: &mut LotusDBVault<LP>, ticket: TopUpTicket) {
    // Permissionless
    public fun td_pool_top_up<LP, Incentive>(
        farm: &mut TDFarm<Incentive>,
        vault: &mut LotusDBVault<LP>,
        top_up_ticket: &mut TopUpTicket,
        clock: &Clock,
    ) {
        top_up_with_acc(farm, &mut vault.incentive_acc, top_up_ticket, clock);

        event::emit(TopUpTDPoolEvent {
            vault_id: object::id(vault),
            td_farm_id: object::id(farm),
            coin_type: type_name::get<Incentive>(),
        });
    }

    public fun destroy_top_up_ticket<LP>(self: &mut LotusDBVault<LP>, ticket: TopUpTicket) {
        destroy_top_up_ticket_with_farm_key(&mut self.farm_key, ticket);
    }

    public(package) fun remove_farm_key_from_td_farm<LP, Incentive>(
        self: &mut LotusDBVault<LP>,
        farm: &mut TDFarm<Incentive>,
        clock: &Clock,
    ) {
        let balance = farm::remove_member<Incentive>(farm, &mut self.farm_key, clock);
        self.incentive_acc.top_up(balance);
    }

    //// ----- Pooling ----- ////
    public fun pooling_deposit<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        lotus_config: &LotusConfig,
        coin_base: Coin<Base>,
        coin_quote: Coin<Quote>,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_aggregator: &OracleAggregator,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_price_object_type<Base>(oracle_aggregator, base_price_info_object);
        assert_price_object_type<Quote>(oracle_aggregator, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_aggregator, deep_price_info_object);
        lotus_config.assert_current_version();
        lotus_config::assert_protocol_status_ok(lotus_config);
        assert_cold_down(self, lotus_config, ctx.sender(), clock);

        let user_address = ctx.sender();
        let vault_usd_value = self.get_total_usd_value(pool, base_price_info_object, quote_price_info_object, deep_price_info_object, oracle_aggregator, clock);
        let coin_base_value = oracle_aggregator.calc_usd_value<Base>(base_price_info_object, coin_base.value(), clock);
        let coin_quote_value = oracle_aggregator.calc_usd_value<Quote>(quote_price_info_object, coin_quote.value(), clock);
        let deposit_total_value = coin_base_value + coin_quote_value;

        assert!(deposit_total_value > lotus_config.get_min_pooling_deposit_value(), EInvalidDeposit);
        // Should initial deposit using `new_for_pooling` when creating vault before pooling deposit.
        assert!(vault_usd_value > 0, EInvalidVaultStatus);      
        // Assert token imbalance
        // abs((Coin base / Coin quote - Self.Balance Base / Self.Balance Quote) - 1) < lotus_config.max_deposit_token_ratio_diff_bps
        let vault_base_value = self.get_total_balance<LP, Base, Base, Quote>(pool);
        let vault_quote_value = self.get_total_balance<LP, Quote, Base, Quote>(pool);
        let p1 = coin_base.value() as u128 * (vault_quote_value as u128);
        let p2 = coin_quote.value() as u128 * (vault_base_value as u128);
        let ratio_diff_bps = if (p1 > p2) {
            (p1 - p2) * 10_000 / p1
        } else {
            (p2 - p1) * 10_000 / p2
        };
        assert!(ratio_diff_bps < std::u64::max_value!() as u128, EOverflow);
        assert!(ratio_diff_bps as u64 < lotus_config.get_max_deposit_token_ratio_diff_bps(), EImbalanceDeposit);

        event::emit(PoolingDepositEvent {
            vault_id: object::id(self),
            user_address: user_address,
            base_amount: coin_base.value(),
            quote_amount: coin_quote.value(),
            deep_amount: 0,
        });

        // Share value P = vault_usd_value / self.total_shares
        // New shares = deposit_total_value / P
        // new_shares = deposit_total_value * self.total_shares / vault_usd_value
        // (All in 6 decimal int representation)
        let new_shares = mul_div_u64(deposit_total_value, self.get_total_shares(), vault_usd_value);
        assert!(new_shares > 0, EInvalidDeposit);
        if (self.user_positions.contains(&user_address)) {
            debug::print(&STD_STRING::utf8(b"user_position.contains"));
            let mut user_original_position = self.user_positions.get_mut(&user_address);
            self.incentive_acc.deposit_shares(user_original_position, new_shares);
        } else {
            debug::print(&STD_STRING::utf8(b"user_position.insert"));
            let user_position = self.incentive_acc.deposit_shares_new(new_shares);
            self.user_positions.insert(user_address, user_position);
        };
        if (self.user_cost.contains(&user_address)) {
            debug::print(&STD_STRING::utf8(b"user_cost.contains"));
            let mut user_original_cost = self.user_cost.get_mut(&user_address);
            *user_original_cost = *user_original_cost + deposit_total_value;
        } else {
            debug::print(&STD_STRING::utf8(b"user_cost.insert"));
            self.user_cost.insert(user_address, deposit_total_value);
        };

        self.balance_manager.deposit_with_cap(&self.deposit_cap, coin_base, ctx);
        self.balance_manager.deposit_with_cap(&self.deposit_cap, coin_quote, ctx);

        self.update_user_last_interaction(ctx.sender(), clock);
    }

    public fun top_up<LP, T>(
        farm: &mut TDFarm<T>,
        vault: &mut LotusDBVault<LP>,
        top_up_ticket: &mut TopUpTicket,
        clock: &Clock,
    ) {
        let balance = farm::member_withdraw_all_with_ticket(farm, &mut top_up_ticket.withdraw_all_ticket, clock);
        acc::top_up(&mut vault.incentive_acc, balance);
    }

    public fun pooling_withdraw<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        lotus_config: &LotusConfig,
        pool: &mut DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_aggregator: &OracleAggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        assert_db_pool(self, pool);
        assert_price_object_type<Base>(oracle_aggregator, base_price_info_object);
        assert_price_object_type<Quote>(oracle_aggregator, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_aggregator, deep_price_info_object);
        lotus_config.assert_current_version();
        lotus_config::assert_protocol_status_ok(lotus_config);
        assert_cold_down(self, lotus_config, ctx.sender(), clock);

        assert!(self.user_positions.contains(&ctx.sender()), EInvalidWithdraw);

        let user_address = ctx.sender();
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        let user_shares = self.user_positions[&user_address].position_shares();
        let (_, user_cost) = self.user_cost.remove(&user_address);
        let vault_usd_value = self.get_total_usd_value(pool, base_price_info_object, quote_price_info_object, deep_price_info_object, oracle_aggregator, clock);
        let user_holding_value = ((vault_usd_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;
        let vault_base_value = self.get_total_balance<LP, Base, Base, Quote>(pool);
        let vault_quote_value = self.get_total_balance<LP, Quote, Base, Quote>(pool);
        let base_value = ((vault_base_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;
        let quote_value = ((vault_quote_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;

        // If available balance < withdraw amount, modify orders.
        // balance_manager.balance<T>() < base_value
        let mut if_update_order = false;
        if (self.balance_manager.balance<Base>() < base_value || self.balance_manager.balance<Quote>() < quote_value) {
            // User share ratio = user_shares / self.total_shares
            // 1. Modify Orders
            let account_order_details: vector<Order> = pool.get_account_order_details(&self.balance_manager);
            let mut i: u64 = 0;
            while (i < account_order_details.length()) {
                let order = &account_order_details[i];
                let order_id = order.order_id();
                // 1.1. Calc withdraw ratio
                // (Quantity - Filled quantity) * (self.total_shares - user_shares) / self.total_shares
                let remain_order_quantity = (order.quantity() - order.filled_quantity()) ;
                let target_order_quantity = mul_div_u64(remain_order_quantity, (self.get_total_shares() - user_shares), self.get_total_shares());
                // 1.2. Quantize to lot size, min size
                let (tick_size, lot_size, min_size) = pool.pool_book_params();
                // 1.3. Modify order
                let quantized_target_order_quantity = target_order_quantity / lot_size * lot_size;
                if (quantized_target_order_quantity < min_size) {
                    // Cancel order
                    pool.cancel_order(&mut self.balance_manager, &trade_proof, order_id, clock, ctx);
                } else {
                    // Modify order
                    pool.modify_order(
                        &mut self.balance_manager,
                        &trade_proof,
                        order_id,
                        quantized_target_order_quantity + order.filled_quantity(),
                        clock,
                        ctx
                    );
                };
                i = i + 1;
            };
            if_update_order = true;
        };
        event::emit(PoolingWithdrawEvent {
            vault_id: object::id(self),
            user_address: user_address,
            base_amount: base_value,
            quote_amount: quote_value,
            deep_amount: 0,
            user_cost: user_cost,
            user_shares: user_shares,
            vault_total_shares: self.incentive_acc.total_shares(),
            if_update_order: if_update_order,
        });

        // 2. Withdraw base and quote pro rata from pool
        pool.withdraw_settled_amounts<Base, Quote>(&mut self.balance_manager, &trade_proof);
        let mut coin_base = self.balance_manager.withdraw_with_cap<Base>(&self.withdraw_cap, base_value, ctx);
        let mut coin_quote = self.balance_manager.withdraw_with_cap<Quote>(&self.withdraw_cap, quote_value, ctx);

        // 2.1 Collect performance fee
        if (user_holding_value > user_cost) {
            // performance fee ratio = (user_holding_value - user_cost) / user_cost * lotus_config.performance_fee_bps / 10000
            // +4 decimal accuracy
            let performance_fee_accrue_bps = mul_div_u64(lotus_config.get_performance_fee_bps(), (user_holding_value - user_cost) * 10_000, user_holding_value);
            let performance_fee_base_amount = mul_div_u64(coin_base.value(), performance_fee_accrue_bps, 10_000 * 10_000);
            let performance_fee_quote_amount = mul_div_u64(coin_quote.value(), performance_fee_accrue_bps, 10_000 * 10_000);
            let strategy_fee_accrue_bps = mul_div_u64(lotus_config.get_strategy_fee_bps(), (user_holding_value - user_cost) * 10_000, user_holding_value);
            let strategy_fee_base_amount = mul_div_u64(coin_base.value(), strategy_fee_accrue_bps, 10_000 * 10_000);
            let strategy_fee_quote_amount = mul_div_u64(coin_quote.value(), strategy_fee_accrue_bps, 10_000 * 10_000);
            if (self.collected_performance_fees.contains(type_name::get<Base>().into_string())) {
                let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_performance_fees[type_name::get<Base>().into_string()];
                base_fee_balance.join(coin::split(&mut coin_base, performance_fee_base_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Base>().into_string(), coin::split(&mut coin_base, performance_fee_base_amount, ctx).into_balance());
            };
            if (self.collected_performance_fees.contains(type_name::get<Quote>().into_string())) {
                let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_performance_fees[type_name::get<Quote>().into_string()];
                quote_fee_balance.join(coin::split(&mut coin_quote, performance_fee_quote_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut coin_quote, performance_fee_quote_amount, ctx).into_balance());
            };
            if (self.collected_strategy_fees.contains(type_name::get<Base>().into_string())) {
                let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_strategy_fees[type_name::get<Base>().into_string()];
                base_fee_balance.join(coin::split(&mut coin_base, strategy_fee_base_amount, ctx).into_balance());
            } else {
                self.collected_strategy_fees.add(type_name::get<Base>().into_string(), coin::split(&mut coin_base, strategy_fee_base_amount, ctx).into_balance());
            };
            if (self.collected_strategy_fees.contains(type_name::get<Quote>().into_string())) {
                let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_strategy_fees[type_name::get<Quote>().into_string()];
                quote_fee_balance.join(coin::split(&mut coin_quote, strategy_fee_quote_amount, ctx).into_balance());
            } else {
                self.collected_strategy_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut coin_quote, strategy_fee_quote_amount, ctx).into_balance());
            };
        };

        // 3. Early withdrawal fee
        if (clock.timestamp_ms() < self.get_user_last_interaction(user_address) + consts::GET_EARLY_WITHDRAWAL_TIMEOUT()) {
            let early_withdrawal_fee_bps = lotus_config.get_early_withdrawal_fee_bps();
            if (early_withdrawal_fee_bps > 0) {
                let early_withdrawal_fee_base_amount = mul_div_u64(coin_base.value(), early_withdrawal_fee_bps, 10_000);
                let early_withdrawal_fee_quote_amount = mul_div_u64(coin_quote.value(), early_withdrawal_fee_bps, 10_000);
                if (self.collected_performance_fees.contains(type_name::get<Base>().into_string())) {
                    let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_performance_fees[type_name::get<Base>().into_string()];
                    base_fee_balance.join(coin::split(&mut coin_base, early_withdrawal_fee_base_amount, ctx).into_balance());
                } else {
                    self.collected_performance_fees.add(type_name::get<Base>().into_string(), coin::split(&mut coin_base, early_withdrawal_fee_base_amount, ctx).into_balance());
                };
                if (self.collected_performance_fees.contains(type_name::get<Quote>().into_string())) {
                    let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_performance_fees[type_name::get<Quote>().into_string()];
                    quote_fee_balance.join(coin::split(&mut coin_quote, early_withdrawal_fee_quote_amount, ctx).into_balance());
                } else {
                    self.collected_performance_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut coin_quote, early_withdrawal_fee_quote_amount, ctx).into_balance());
                };
            };
        };

        // 4. Withdraw shares from acc
        let (_, mut position) = self.user_positions.remove(&user_address);
        self.incentive_acc.withdraw_shares(&mut position, user_shares);
        position.position_destroy_empty();

        self.update_user_last_interaction(ctx.sender(), clock);

        (coin_base, coin_quote)
    }

    public fun pooling_redeem_incentive<LP, Incentive>(
        self: &mut LotusDBVault<LP>,
        ticket: TopUpTicket,
        ctx: &mut TxContext,
    ): Coin<Incentive> {
        destroy_top_up_ticket_with_farm_key(&mut self.farm_key, ticket);
        let mut position = self.user_positions.get_mut(&ctx.sender());
        let balance = self.incentive_acc.withdraw_all_rewards<Incentive>(position);
        event::emit(RedeemIncentivesEvent {
            vault_id: object::id(self),
            incentive_type: type_name::get<Incentive>(),
            incentive_value: balance.value(),
        });
        balance.into_coin(ctx)
    }

    //// ===== Admin Functions ===== ////
    public fun withdraw_collected_performance_fees<LP, T>(
        self: &mut LotusDBVault<LP>,
        lotus_config_cap: &LotusConfigCap,
        ctx: &mut TxContext,
    ): Coin<T> {
        let type_name = type_name::get<T>().into_string();
        if (self.collected_performance_fees.contains(type_name)) {
            let mut balance: Balance<T> = self.collected_performance_fees.remove(type_name);
            balance.into_coin(ctx)
        } else {
            coin::zero(ctx)
        }
    }

    public fun withdraw_collected_strategy_fees<LP, T>(
        self: &mut LotusDBVault<LP>,
        vault_cap: &LotusDBVaultCap,
        ctx: &mut TxContext,
    ): Coin<T> {
        self.assert_vault_cap_access(vault_cap, PCreatorAccess);
        let type_name = type_name::get<T>().into_string();
        if (self.collected_strategy_fees.contains(type_name)) {
            let mut balance: Balance<T> = self.collected_strategy_fees.remove(type_name);
            balance.into_coin(ctx)
        } else {
            coin::zero(ctx)
        }
    }

    // Distribute tokens to users on purge
    // Called before purge vault, access by admin
    public fun admin_distribute_tokens_to_pooling_user_on_purge<LP, Base, Quote>(
        self: &mut LotusDBVault<LP>,
        lotus_config: &LotusConfig,
        lotus_config_cap: &LotusConfigCap,
        pool: &mut DBPool<Base, Quote>,
        target_user: address,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_aggregator: &OracleAggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_db_pool(self, pool);
        assert_price_object_type<Base>(oracle_aggregator, base_price_info_object);
        assert_price_object_type<Quote>(oracle_aggregator, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_aggregator, deep_price_info_object);
        lotus_config.assert_current_version();
        lotus_config::assert_protocol_status_ok(lotus_config);

        let user_address = target_user;
        let trade_proof = self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx);
        let user_shares = self.user_positions[&user_address].position_shares();
        let (_, user_cost) = self.user_cost.remove(&user_address);
        let vault_usd_value = self.get_total_usd_value(pool, base_price_info_object, quote_price_info_object, deep_price_info_object, oracle_aggregator, clock);
        let user_holding_value = ((vault_usd_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;
        let vault_base_value = self.get_total_balance<LP, Base, Base, Quote>(pool);
        let vault_quote_value = self.get_total_balance<LP, Quote, Base, Quote>(pool);
        let base_value = ((vault_base_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;
        let quote_value = ((vault_quote_value as u128) * (user_shares as u128) / (self.incentive_acc.total_shares() as u128)) as u64;

        event::emit(PoolingWithdrawEvent {
            vault_id: object::id(self),
            user_address: user_address,
            base_amount: base_value,
            quote_amount: quote_value,
            deep_amount: 0,
            user_cost: user_cost,
            user_shares: user_shares,
            vault_total_shares: self.incentive_acc.total_shares(),
            if_update_order: true,
        });
        // User share ratio = user_shares / self.total_shares
        // 1. Cancel All Orders
        pool.cancel_all_orders(&mut self.balance_manager, &trade_proof, clock, ctx);
        // 2. Withdraw base and quote pro rata from pool
        pool.withdraw_settled_amounts<Base, Quote>(&mut self.balance_manager, &trade_proof);
        let mut coin_base = self.balance_manager.withdraw_with_cap<Base>(&self.withdraw_cap, base_value, ctx);
        let mut coin_quote = self.balance_manager.withdraw_with_cap<Quote>(&self.withdraw_cap, quote_value, ctx);

        // 2.1 Collect performance fee
        if (user_holding_value > user_cost) {
            // performance fee ratio = (user_holding_value - user_cost) / user_cost * lotus_config.performance_fee_bps / 10000
            let performance_fee_accrue_bps = mul_div_u64(lotus_config.get_performance_fee_bps(), (user_holding_value - user_cost) * 10_000, user_holding_value);
            let performance_fee_base_amount = mul_div_u64(coin_base.value(), performance_fee_accrue_bps, 10_000 * 10_000);
            let performance_fee_quote_amount = mul_div_u64(coin_quote.value(), performance_fee_accrue_bps, 10_000 * 10_000);
            let strategy_fee_accrue_bps = mul_div_u64(lotus_config.get_strategy_fee_bps(), (user_holding_value - user_cost) * 10_000, user_holding_value);
            let strategy_fee_base_amount = mul_div_u64(coin_base.value(), strategy_fee_accrue_bps, 10_000 * 10_000);
            let strategy_fee_quote_amount = mul_div_u64(coin_quote.value(), strategy_fee_accrue_bps, 10_000 * 10_000);
            if (self.collected_performance_fees.contains(type_name::get<Base>().into_string())) {
                let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_performance_fees[type_name::get<Base>().into_string()];
                base_fee_balance.join(coin::split(&mut coin_base, performance_fee_base_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Base>().into_string(), coin::split(&mut coin_base, performance_fee_base_amount, ctx).into_balance());
            };
            if (self.collected_performance_fees.contains(type_name::get<Quote>().into_string())) {
                let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_performance_fees[type_name::get<Quote>().into_string()];
                quote_fee_balance.join(coin::split(&mut coin_quote, performance_fee_quote_amount, ctx).into_balance());
            } else {
                self.collected_performance_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut coin_quote, performance_fee_quote_amount, ctx).into_balance());
            };
            if (self.collected_strategy_fees.contains(type_name::get<Base>().into_string())) {
                let mut base_fee_balance: &mut Balance<Base> = &mut self.collected_strategy_fees[type_name::get<Base>().into_string()];
                base_fee_balance.join(coin::split(&mut coin_base, strategy_fee_base_amount, ctx).into_balance());
            } else {
                self.collected_strategy_fees.add(type_name::get<Base>().into_string(), coin::split(&mut coin_base, strategy_fee_base_amount, ctx).into_balance());
            };
            if (self.collected_strategy_fees.contains(type_name::get<Quote>().into_string())) {
                let mut quote_fee_balance: &mut Balance<Quote> = &mut self.collected_strategy_fees[type_name::get<Quote>().into_string()];
                quote_fee_balance.join(coin::split(&mut coin_quote, strategy_fee_quote_amount, ctx).into_balance());
            } else {
                self.collected_strategy_fees.add(type_name::get<Quote>().into_string(), coin::split(&mut coin_quote, strategy_fee_quote_amount, ctx).into_balance());
            };
        };

        // 3. Withdraw shares from acc
        let (_, mut position) = self.user_positions.remove(&user_address);
        self.incentive_acc.withdraw_shares(&mut position, user_shares);
        position.position_destroy_empty();

        transfer::public_transfer(coin_base, target_user);
        transfer::public_transfer(coin_quote, target_user);
    }

    public fun admin_distribute_incentive_to_pooling_user_on_purge<LP, Incentive>(
        self: &mut LotusDBVault<LP>,
        lotus_config_cap: &LotusConfigCap,
        target_user: address,
        ticket: TopUpTicket,
        ctx: &mut TxContext,
    ) {
        destroy_top_up_ticket_with_farm_key(&mut self.farm_key, ticket);
        let mut position = self.user_positions.get_mut(&target_user);
        let balance = self.incentive_acc.withdraw_all_rewards<Incentive>(position);
        transfer::public_transfer(balance.into_coin(ctx), target_user);
    }

    // Used in rescue mode. Don't call this normally since it will left some incentive not topped up in the TDFarm.
    public fun admin_distribute_incentive_to_pooling_user_on_purge_direct<LP, Incentive>(
        self: &mut LotusDBVault<LP>,
        lotus_config_cap: &LotusConfigCap,
        target_user: address,
        ctx: &mut TxContext,
    ) {
        let mut position = self.user_positions.get_mut(&target_user);
        let balance = self.incentive_acc.withdraw_all_rewards<Incentive>(position);
        transfer::public_transfer(balance.into_coin(ctx), target_user);
    }

    //// ====== Setter Functions ====== ////
    public fun update_strategy_params<LP>(
        self: &mut LotusDBVault<LP>,
        vault_cap: &LotusDBVaultCap,
        key: String,
        value: u64,
    ) {
        self.assert_vault_cap_access(vault_cap, PCreatorAccess);
        if (self.strategy_params.contains(key)) {
            let mut original_value = self.strategy_params.borrow_mut(key);
            *original_value = value;
        } else {
            self.strategy_params.add(key, value);
        };

        event::emit(UpdateStrategyParamsEvent {
            vault_id: object::id(self),
            key: key,
            value: value,
        });
    }

    //// ====== Inspection Functions ====== ////
    // Get balance value for a coin T.
    // Need to provide pool type.
    public fun get_total_balance<LP, T, Base, Quote>(
        self: &LotusDBVault<LP>, 
        pool: &DBPool<Base, Quote>
    ): u64 {
        assert_db_pool(self, pool);
        // get balance manager value
        let bm_balance = self.balance_manager.balance<T>();
        let (base_balance, quote_balance, deep_balance) = pool.locked_balance<Base, Quote>(&self.balance_manager);
        
        // return directly on each conditions
        if (type_name::get<T>() == type_name::get<Quote>()) {
            bm_balance + quote_balance
        } else if (type_name::get<T>() == type_name::get<Base>()) {
            bm_balance + base_balance
        } else if (type_name::get<T>() == type_name::get<DEEP>()) {
            bm_balance + deep_balance
        } else {
            bm_balance
        }
    }

    public fun get_total_usd_value<LP, Base, Quote>(
        self: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_aggregator: &OracleAggregator,
        clock: &Clock,
    ): u64 {
        assert_db_pool(self, pool);
        assert_price_object_type<Base>(oracle_aggregator, base_price_info_object);
        assert_price_object_type<Quote>(oracle_aggregator, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_aggregator, deep_price_info_object);
        let base_value_float = oracle_aggregator.calc_usd_value<Base>(base_price_info_object, get_total_balance<LP, Base, Base, Quote>(self, pool), clock);
        let quote_value_float = oracle_aggregator.calc_usd_value<Quote>(quote_price_info_object, get_total_balance<LP, Quote, Base, Quote>(self, pool), clock);
        let deep_value_float = oracle_aggregator.calc_usd_value<DEEP>(deep_price_info_object, get_total_balance<LP, DEEP, Base, Quote>(self, pool), clock);
        if (type_name::get<Base>() == type_name::get<DEEP>() || type_name::get<Quote>() == type_name::get<DEEP>()) {
            base_value_float + quote_value_float
        } else {
            base_value_float + quote_value_float + deep_value_float
        }
    }

    // public fun get_stake_value<LP>(self: &LotusDBVault<LP>): u64{
    //     let stake = self.stake.borrow();
    //     stake.stake_balance<LP>()
    // }

    public fun get_incentive_value<LP, Incentive>(self: &LotusDBVault<LP>): u64 {
        self.incentive_acc.balance_value<Incentive>()
    }

    public fun get_incentive_value_for_user<LP, Incentive>(
        self: &LotusDBVault<LP>,
        user_address: address,
    ): u64 {
        if (self.user_positions.contains(&user_address)) {
            let position = &self.user_positions[&user_address];
            self.incentive_acc.position_rewards_value_with_type<Incentive>(position)
        } else {
            0
        }
    }

    public fun account<LP, Base, Quote>(
        self: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
    ): Account {
        assert_db_pool(self, pool);
        pool.account(&self.balance_manager)
    }

    public fun account_open_orders<LP, Base, Quote>(
        self: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
    ): VecSet<u128> {
        assert_db_pool(self, pool);
        pool.account_open_orders(&self.balance_manager)
    }

    public fun get_account_order_details<LP, Base, Quote>(
        self: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
    ): vector<Order> {
        assert_db_pool(self, pool);
        pool.get_account_order_details(&self.balance_manager)
    }

    public fun bm_balance<LP, T>(self: &LotusDBVault<LP>): u64 { self.balance_manager.balance<T>() }

    public fun balance_manager_id<LP>(self: &LotusDBVault<LP>): ID { object::id(&self.balance_manager) }

    public fun get_td_farm_member_key_id<LP>(self: &LotusDBVault<LP>): ID { object::id(&self.farm_key) }

    public fun get_user_and_total_shares<LP>(
        self: &LotusDBVault<LP>,
        user_address: address,
    ): (u64, u64) {
        let user_shares = if (self.user_positions.contains(&user_address)) {
            self.user_positions[&user_address].position_shares()
        } else {
            0
        };
        (user_shares, self.incentive_acc.total_shares())
    }

    public fun get_total_shares<LP>(self: &LotusDBVault<LP>): u64 { self.incentive_acc.total_shares() }

    public fun get_user_cost<LP>(
        self: &LotusDBVault<LP>,
        user_address: address,
    ): u64 {
        if (self.user_cost.contains(&user_address)) {
            *self.user_cost.get(&user_address)
        } else {
            0
        }
    }

    public fun get_user_last_interaction<LP>(
        self: &LotusDBVault<LP>,
        user_address: address,
    ): u64 {
        if (self.user_last_interaction.contains(&user_address)) {
            *self.user_last_interaction.get(&user_address)
        } else {
            0
        }
    }

    public fun get_shareholder_address_vec<LP>(self: &LotusDBVault<LP>): vector<address> { self.user_positions.keys() }

    // Omitted since we use client side dynamic field query on shared vault.
    public fun get_strategy_params<LP>(self: &LotusDBVault<LP>) { }

    //// ====== Assertions Functions ====== ////
    public(package) fun assert_vault_cap_access<LP>(self: &LotusDBVault<LP>, cap: &LotusDBVaultCap, flag: u64) {
        assert!(object::id(self) == cap.vault_id, EInvalidAccess);
        assert!(cap.access_flag & PMasterAccess > 0 || cap.access_flag & flag > 0, EInvalidAccess);
    }
    public(package) fun assert_db_pool<LP, Base, Quote>(self: &LotusDBVault<LP>, pool: &DBPool<Base, Quote>) {
        assert!(self.allowed_pool == object::id(pool), EUnauthorizedDBPool);
    }
    public(package) fun assert_cold_down<LP>(self: &mut LotusDBVault<LP>, lotus_config: &LotusConfig, user_address: address, clock: &Clock) {
        lotus_config.assert_current_version();
        let cold_down_ms = lotus_config.get_cold_down_ms();
        if (self.user_last_interaction.contains(&user_address)) {
            let mut user_last_interaction = self.user_last_interaction.get_mut(&user_address);
            assert!(clock.timestamp_ms() - *user_last_interaction > cold_down_ms, EOperationColdDown);
            *user_last_interaction = clock.timestamp_ms();
        };
    }
    public(package) fun update_user_last_interaction<LP>(self: &mut LotusDBVault<LP>, user_address: address, clock: &Clock) {
        if (self.user_last_interaction.contains(&user_address)) {
            let mut user_last_interaction = self.user_last_interaction.get_mut(&user_address);
            *user_last_interaction = clock.timestamp_ms();
        } else {
            self.user_last_interaction.insert(user_address, clock.timestamp_ms());
        };
    }
    public(package) fun assert_valid_strategy_params<LP>(
        self: &LotusDBVault<LP>,
    ) {
        assert!(self.strategy_params.contains(utf8(b"strategy_type")), EInvalidStrategyParams);
        let strategy_type = self.strategy_params.borrow(utf8(b"strategy_type"));
        if (strategy_type == 1) {
            assert!(self.strategy_params.contains(utf8(b"upper")), EInvalidStrategyParams);
            assert!(self.strategy_params.contains(utf8(b"lower")), EInvalidStrategyParams);
            assert!(self.strategy_params.contains(utf8(b"n-levels")), EInvalidStrategyParams);
            assert!(self.strategy_params.contains(utf8(b"size")), EInvalidStrategyParams);
        }
    }

    public(package) fun is_strategy_in_range<LP, Base, Quote>(
        self: &LotusDBVault<LP>, 
        pool: &DBPool<Base, Quote>,
        price_base: &PriceInfoObject,
        price_quote: &PriceInfoObject,
        ag: &OracleAggregator,
        clock: &Clock,
    ): bool {
        assert_db_pool(self, pool);
        ag.assert_price_object_type<Base>(price_base);
        ag.assert_price_object_type<Quote>(price_quote);
        self.assert_valid_strategy_params();
        let strategy_type = self.strategy_params.borrow(utf8(b"strategy_type"));
        if (strategy_type == 1) {
            // Grid strategy
            let upper = self.strategy_params[utf8(b"upper")];
            let lower = self.strategy_params[utf8(b"lower")];
            let (price_base, price_decimal_base, _) = ag.get_price<Base>(price_base, clock);
            let (price_quote, price_decimal_quote, _) = ag.get_price<Quote>(price_quote, clock);
            let coin_decimal_base = ag.get_coin_decimal<Base>();
            let coin_decimal_quote = ag.get_coin_decimal<Quote>();
            // actual_price = (price_base / 10^price_decimal_base) / (price_quote / 10^price_decimal_quote)
            // order_price = actual_price * 10^(9 + coin_quote_decimal - coin_base_decimal)
            // Keep integer: order_price = (price_base * 10^(price_decimal_quote + 9 + coin_quote_decimal)) / (price_quote * 10^(price_decimal_base + coin_base_decimal))
            let order_price = ((price_base as u256 * 10u256.pow((price_decimal_quote as u8 + 9 as u8) + coin_decimal_quote)) / 
                                (price_quote as u256 * 10u256.pow((price_decimal_base as u8 + coin_decimal_base as u8))));
            assert!(order_price < u64::max_value!() as u256, EInvalidStrategyParams);
            if (order_price as u64 > upper || order_price as u64 < lower) {
                false
            } else {
                true
            }
        } else {
            assert!(false);
            false // Placeholder for compilation
        }
    }

}