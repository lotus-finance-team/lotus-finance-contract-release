module lotus_finance::lotus_vault_db_related_tests {
    use std::debug;
    use std::type_name::{Self, TypeName};
    use sui::sui::SUI;
    use sui::vec_set::{Self, VecSet};
    use std::string::{Self, String, utf8};
    use sui::clock::{Self, Clock};
    use sui::test_utils;
    use sui::coin::{Self, Coin, TreasuryCap, mint_for_testing};
    use sui::test_scenario::{Self,Scenario, begin, end, return_shared, return_to_address};
    // Deepbook
    use token::deep::DEEP;
    use deepbook::constants;
    use deepbook::order_info::OrderInfo;
    use deepbook::balance_manager::{Self, BalanceManager, TradeCap};
    use deepbook::pool::{Self as db_pool, Pool as DBPool};
    use deepbook::registry::{Self, Registry};
    // Pyth
    use pyth::price_info;
    // Lotus
    use lotus_finance::lp_token::{Self, LP_TOKEN};
    use lotus_finance::lotus_db_vault::{Self, LotusDBVault, LotusDBVaultCap};
    use lotus_finance::lotus_lp_farm::{Self, LotusLPFarm, LotusLPFarmCap, LotusLPFarmCreateVaultTicket};
    use lotus_finance::oracle_ag;
    use lotus_finance::lotus_math::{mul, div};
    use lotus_finance::lotus_config::{Self, LotusConfig, LotusConfigCap};
    use lotus_finance::test_utils::{create_clock_at_sec, build_pyth_price_info_object, MY_SUI, MY_DEEP, set_clock_sec, setup_lotus_lp_farm, assert_proximity};

    const OWNER: address = @0x1;
    const DELEGATE: address = @0xD;

    public struct USDC has store {}
    public struct SPAM has store {}
    public struct AIRE has store {}
    public struct USDT has store {}
    
    public struct ExpectedBalance has drop {
        usdc: u64,
        usdt: u64,
        deep: u64,
        sui:  u64,
        spam: u64,
    }

    public struct LOTUS_VAULT_DB_RELATED_TESTS has drop {}

    //// === Deepbook Related Setup === ////
    #[test_only]
    /// Set the time in the global clock to 1_000_000 + current_time
    public(package) fun set_time(current_time: u64, test: &mut Scenario) {
        test.next_tx(OWNER);
        {
            let mut clock = test.take_shared<Clock>();
            clock.set_for_testing(current_time + 1_000_000);
            return_shared(clock);
        };
    }

    #[test_only]
    public(package) fun add_deep_price_point<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(
        sender: address,
        target_pool_id: ID,
        reference_pool_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let mut target_pool = test.take_shared_by_id<
                DBPool<BaseAsset, QuoteAsset>,
            >(target_pool_id);
            let reference_pool = test.take_shared_by_id<
                DBPool<ReferenceBaseAsset, ReferenceQuoteAsset>,
            >(reference_pool_id);
            let clock = test.take_shared<Clock>();
            db_pool::add_deep_price_point<
                BaseAsset,
                QuoteAsset,
                ReferenceBaseAsset,
                ReferenceQuoteAsset,
            >(
                &mut target_pool,
                &reference_pool,
                &clock,
            );
            return_shared(target_pool);
            return_shared(reference_pool);
            return_shared(clock);
        }
    }

    #[test_only]
    fun setup_pool<BaseAsset, QuoteAsset>(
        sender: address,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        registry_id: ID,
        whitelisted_pool: bool,
        stable_pool: bool,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let pool_id;
        {
            pool_id =
                db_pool::create_pool_admin<BaseAsset, QuoteAsset>(
                    &mut registry,
                    tick_size,
                    lot_size,
                    min_size,
                    whitelisted_pool,
                    stable_pool,
                    &admin_cap,
                    test.ctx(),
                );
        };
        return_shared(registry);
        test_utils::destroy(admin_cap);

        pool_id
    }

    #[test_only]
    public(package) fun setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        sender: address,
        registry_id: ID,
        whitelisted_pool: bool,
        stable_pool: bool,
        test: &mut Scenario,
    ): ID {
        setup_pool<BaseAsset, QuoteAsset>(
            sender,
            constants::tick_size(), // tick size
            constants::lot_size(), // lot size
            constants::min_size(), // min size
            registry_id,
            whitelisted_pool,
            stable_pool,
            test,
        )
    }

    #[test_only]
    /// Place a limit order
    public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
        trader: address,
        pool_id: ID,
        balance_manager_id: ID,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ): OrderInfo {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared_by_id<DBPool<BaseAsset, QuoteAsset>>(
                pool_id,
            );
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(
                balance_manager_id,
            );
            let trade_proof;

            let is_owner = balance_manager.owner() == trader;
            if (is_owner) {
                trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
            } else {
                let trade_cap = test.take_from_sender<TradeCap>();
                trade_proof =
                    balance_manager.generate_proof_as_trader(
                        &trade_cap,
                        test.ctx(),
                    );
                test.return_to_sender(trade_cap);
            };

            // Place order in pool
            let order_info = pool.place_limit_order<BaseAsset, QuoteAsset>(
                &mut balance_manager,
                &trade_proof,
                client_order_id,
                order_type,
                self_matching_option,
                price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &clock,
                test.ctx(),
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(balance_manager);

            order_info
        }
    }

    #[test_only]
    /// Set up a reference pool where Deep per base is 100
    public(package) fun setup_reference_pool<BaseAsset, QuoteAsset>(
        sender: address,
        registry_id: ID,
        balance_manager_id: ID,
        deep_multiplier: u64,
        test: &mut Scenario,
    ): ID {
        let reference_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
            sender,
            registry_id,
            true,
            false,
            test,
        );

        place_limit_order<BaseAsset, QuoteAsset>(
            sender,
            reference_pool_id,
            balance_manager_id,
            1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            deep_multiplier - 80 * constants::float_scaling(),
            1 * constants::float_scaling(),
            true,
            true,
            std::u64::max_value!(),
            test,
        );

        place_limit_order<BaseAsset, QuoteAsset>(
            sender,
            reference_pool_id,
            balance_manager_id,
            1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            deep_multiplier + 80 * constants::float_scaling(),
            1 * constants::float_scaling(),
            false,
            true,
            std::u64::max_value!(),
            test,
        );

        reference_pool_id
    }

    #[test_only]
    public(package) fun setup_pool_with_default_fees_and_reference_pool<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(
        sender: address,
        registry_id: ID,
        balance_manager_id: ID,
        test: &mut Scenario,
    ): ID {
        let target_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
            OWNER,
            registry_id,
            false,
            false,
            test,
        );
        let reference_pool_id = setup_reference_pool<
            ReferenceBaseAsset,
            ReferenceQuoteAsset,
        >(
            sender,
            registry_id,
            balance_manager_id,
            constants::deep_multiplier(),
            test,
        );
        set_time(0, test);
        add_deep_price_point<
            BaseAsset,
            QuoteAsset,
            ReferenceBaseAsset,
            ReferenceQuoteAsset,
        >(
            sender,
            target_pool_id,
            reference_pool_id,
            test,
        );

        target_pool_id
    }

    #[test_only]
    fun share_clock(test: &mut Scenario) {
        test.next_tx(OWNER);
        clock::create_for_testing(test.ctx()).share_for_testing();
    }
    #[test_only]
    fun share_registry_for_testing(test: &mut Scenario): ID {
        test.next_tx(OWNER);
        registry::test_registry(test.ctx())
    }
    #[test_only]
    public(package) fun setup_test(owner: address, test: &mut Scenario): ID {
        test.next_tx(owner);
        share_clock(test);
        share_registry_for_testing(test)
    }

    #[test_only]
    public(package) fun deposit_into_account<T>(
        balance_manager: &mut BalanceManager,
        amount: u64,
        test: &mut Scenario,
    ) {
        balance_manager.deposit(
            mint_for_testing<T>(amount, test.ctx()),
            test.ctx(),
        );
    }

    #[test_only]
    public(package) fun create_acct_and_share_with_funds(
        sender: address,
        amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            deposit_into_account<SUI>(&mut balance_manager, amount, test);
            deposit_into_account<SPAM>(&mut balance_manager, amount, test);
            deposit_into_account<USDC>(&mut balance_manager, amount, test);
            deposit_into_account<DEEP>(&mut balance_manager, amount, test);
            deposit_into_account<USDT>(&mut balance_manager, amount, test);
            let trade_cap = balance_manager.mint_trade_cap(test.ctx());
            transfer::public_transfer(trade_cap, sender);
            let id = object::id(&balance_manager);
            transfer::public_share_object(balance_manager);

            id
        }
    }

    #[test_only]
    fun check_total_balance<Base, Quote>(
        vault: &LotusDBVault<LOTUS_VAULT_DB_RELATED_TESTS>,
        db_pool: &DBPool<Base, Quote>,
        expected_balance: &ExpectedBalance,

    ) {
        assert!(vault.get_total_balance<LOTUS_VAULT_DB_RELATED_TESTS, SUI, Base, Quote>(db_pool) == expected_balance.sui);
        assert!(vault.get_total_balance<LOTUS_VAULT_DB_RELATED_TESTS, USDC, Base, Quote>(db_pool) == expected_balance.usdc);
        assert!(vault.get_total_balance<LOTUS_VAULT_DB_RELATED_TESTS, USDT, Base, Quote>(db_pool) == expected_balance.usdt);
        assert!(vault.get_total_balance<LOTUS_VAULT_DB_RELATED_TESTS, DEEP, Base, Quote>(db_pool) == expected_balance.deep);
        assert!(vault.get_total_balance<LOTUS_VAULT_DB_RELATED_TESTS, SPAM, Base, Quote>(db_pool) == expected_balance.spam);
    }

    #[test_only]
    fun expected_balance_zeros(): ExpectedBalance {
        ExpectedBalance { usdc: 0, usdt: 0, deep: 0, sui: 0, spam: 0 }
    }

    //// ====== Business Logic Tests ====== ////
    #[test]
    public fun test_place_order_walkthrough() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let delegate = @0xD;
        let spam = 0xEEE;
        
        let registry_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            user,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(user, registry_id, balance_manager_id_alice, &mut test);

        // User operations.
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            let clock = create_clock_at_sec(1001, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let (mut vault, vault_creator_cap, lotus_trade_cap) = lotus_db_vault::new_for_pooling<LOTUS_VAULT_DB_RELATED_TESTS>(db_pool_id, 0, &clock, test.ctx());

            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1000);

            // Base: SUI, Quote: USDC
            let base_scale = 1_000_000_000;
            let quote_scale = 1_000_000;
            let deep_scale = 1_000_000;

            //// ------ Test case ------ ////
            // Price:
            //   - SUI: 4
            //   - USDC: 1
            //   - DEEP: 0.1
            // User:
            //   - 10.2 SUI
            //   - 23.2 USDC 
            //   - 1770 DEEP
            // Expected total USD value: 10.2 * 4 + 23.2 * 1 + 1770 * 0.1 = 241
            let sui_balance: u64 = 10_200_000_000;
            let usdc_balance: u64 = 23_200_000;
            let deep_balance: u64 = 1_770_000_000;

            // Deposit some fund into the vault
            vault.deposit<SUI, LOTUS_VAULT_DB_RELATED_TESTS>(
                mint_for_testing<SUI>(sui_balance, test.ctx()), test.ctx(),
            );

            vault.deposit<USDC, LOTUS_VAULT_DB_RELATED_TESTS>(
                mint_for_testing<USDC>(usdc_balance, test.ctx()), test.ctx(),
            );

            vault.deposit<DEEP, LOTUS_VAULT_DB_RELATED_TESTS>(
                mint_for_testing<DEEP>(deep_balance, test.ctx()), test.ctx(),
            );

            let mut expected_balance = expected_balance_zeros();
            expected_balance.sui = sui_balance;
            expected_balance.usdc = usdc_balance;
            expected_balance.deep = deep_balance;
            check_total_balance(&vault, &db_pool, &expected_balance);

            // Test vault USD balance            
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1000);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000);
            ag.update_pyth_price_id<SUI>(&ag_cap, sui_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<USDC>(&ag_cap, usdc_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<DEEP>(&ag_cap, deep_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_decimal<DEEP>(&ag_cap, 6);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<DEEP>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());

            let expected_total_usd_value: u64 = 241_000_000;
            let calc_total_usd_value = vault.get_total_usd_value<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(
                &db_pool, 
                &sui_price_info_object, 
                &usdc_price_info_object, 
                &deep_price_info_object, 
                &ag,
                &clock
            );
            
            // Place a limit order
            let client_order_id = 1;
            let order_type = constants::no_restriction();
            // price = 2 * float_scaling * quote_scaling / base_scaling
            let price = 1 * div(mul(constants::float_scaling(), quote_scale), base_scale);
            let quantity = 2 * base_scale;
            let expire_timestamp = std::u64::max_value!();
            let pay_with_deep = true;
            let maker_fee = constants::maker_fee();
            let deep_multiplier = constants::deep_multiplier();

            // Place bid limit order
            vault.place_limit_order<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(
                &lotus_trade_cap,
                &mut db_pool,
                client_order_id,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                pay_with_deep,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            vault.place_limit_order<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(
                &lotus_trade_cap,
                &mut db_pool,
                client_order_id + 1,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                pay_with_deep,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            vault.place_limit_order<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(
                &lotus_trade_cap,
                &mut db_pool,
                client_order_id + 2,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                pay_with_deep,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            // Test vault balance and USD value again
            check_total_balance(&vault, &db_pool, &expected_balance);
            let calc_total_usd_value_2 = vault.get_total_usd_value<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(
                &db_pool, 
                &sui_price_info_object, 
                &usdc_price_info_object, 
                &deep_price_info_object, 
                &ag,
                &clock
            );
            assert!(calc_total_usd_value_2 == expected_total_usd_value);

            // account open orders
            let open_order_ids: VecSet<u128> = vault.account_open_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&db_pool);
            assert!(open_order_ids.size() == 3);
            let open_order_details = vault.get_account_order_details<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&db_pool);
            assert!(open_order_details[0].client_order_id() == client_order_id);
            assert!(open_order_details[0].quantity() == quantity);

            // Cancel order
            vault.cancel_order<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&lotus_trade_cap, &mut db_pool, open_order_details[0].order_id(), &clock, test.ctx());
            let open_order_ids_2: VecSet<u128> = vault.account_open_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&db_pool);
            assert!(open_order_ids_2.size() == 2);
            // Cancel orders
            vault.cancel_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&lotus_trade_cap, &mut db_pool, open_order_ids_2.into_keys(), &clock, test.ctx());
            assert!(vault.account_open_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&db_pool).size() == 0);
            // Cancel all orders
            vault.place_limit_order<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&lotus_trade_cap, &mut db_pool, client_order_id + 3, order_type, constants::self_matching_allowed(), price, quantity, true, pay_with_deep, expire_timestamp, &clock, test.ctx());
            vault.cancel_all_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&lotus_trade_cap, &mut db_pool, &clock, test.ctx());
            assert!(vault.account_open_orders<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&db_pool).size() == 0);

            // Withdraw and redeem
            vault.withdraw_settled_amounts<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&mut db_pool, test.ctx());
            let (sui, usdc, _deep) = vault.redeem_all_token_base_quote_deep<LOTUS_VAULT_DB_RELATED_TESTS, SUI, USDC>(&vault_creator_cap, &lotus_config, &db_pool, &sui_price_info_object, &usdc_price_info_object, &deep_price_info_object, &ag, &clock, test.ctx());
            debug::print(&usdc.balance().value());
            assert_proximity(usdc.balance().value(), usdc_balance * 9 / 10, 10);

            let usdc_fee = vault.withdraw_collected_performance_fees<LOTUS_VAULT_DB_RELATED_TESTS, USDC>(&lotus_config_cap, test.ctx());
            assert_proximity(usdc_fee.balance().value(), usdc_balance / 10, 10);

            // Clean up
            transfer::public_share_object(usdc);
            transfer::public_share_object(sui);
            transfer::public_share_object(_deep);
            transfer::public_share_object(usdc_fee);
            price_info::destroy(sui_price_info_object);
            price_info::destroy(usdc_price_info_object);
            price_info::destroy(deep_price_info_object);

            transfer::public_share_object(vault);
            transfer::public_transfer(vault_creator_cap, user);
            transfer::public_transfer(lotus_trade_cap, user);
            return_shared(db_pool);
            return_shared(ag);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            return_to_address(user, ag_cap);
            clock::destroy_for_testing(clock);
        };

        end(test);
    }

    #[test]
    public fun test_update_vault_weight() {
        // OWNER init
        let user = @0xA;
        let delegate = @0xD;
        let spam = 0xEEE;

        let mut test = begin(user);
        
        // Deepbook init
        let registry_id = setup_test(user, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            user,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(user, registry_id, balance_manager_id_alice, &mut test);

        // Farm init
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        // User operations.
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);

            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1000);

            // Farm
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 200, test.ctx());
            lp_farm.add_td_farm<LP_TOKEN, AIRE>(&lp_farm_admin_cap, 200, test.ctx());

            // Test vault USD balance            
            // Price:
            //   - SUI: 4
            //   - USDC: 1
            //   - DEEP: 0.1
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 99);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 99);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 99);
            ag.update_pyth_price_id<SUI>(&ag_cap, sui_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<USDC>(&ag_cap, usdc_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<DEEP>(&ag_cap, deep_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_decimal<DEEP>(&ag_cap, 6);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<DEEP>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());

            // -- Vault from farm --
            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(330_000_000_000, test.ctx()),
                mint_for_testing<USDC>(300_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, AIRE>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // -- Vault dummy --
            let (mut vault_dummy, vault_dummy_creator_cap, vault_dummy_trade_cap, mut create_vault_dummy_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(990_000_000_000, test.ctx()),
                mint_for_testing<USDC>(900_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault_dummy, &mut create_vault_dummy_ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, AIRE>(&mut vault_dummy, &mut create_vault_dummy_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_dummy_ticket);

            // -- Topup td_farm --
            let coin: Coin<SPAM> = mint_for_testing<SPAM>(110_000_000_000, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, SPAM>(coin, &clock);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 100, &clock, test.ctx());
            let coin: Coin<AIRE> = mint_for_testing<AIRE>(100_000_000, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, AIRE>(coin, &clock);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, AIRE>(&lp_farm_admin_cap, 200, &clock, test.ctx());

            // -- Distribute --
            // T = 250
            set_clock_sec(&mut clock, 250);
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault, &mut top_up_ticket, &clock);

            assert_proximity(vault.get_incentive_value<LP_TOKEN, SPAM>(), 1250, 5);
            let vault_spam = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());

            let mut top_up_ticket_dummy = vault_dummy.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);
            let vault_dummy_spam = vault_dummy.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket_dummy, test.ctx());

            assert_proximity(vault_spam.value(), 1250, 5);
            assert_proximity(vault_dummy_spam.value(), 3750, 5);

            // -- Update vault weight --
            vault.deposit<USDC, LP_TOKEN>(
                mint_for_testing<USDC>(3_060_000_000, test.ctx()), test.ctx(),
            );

            let sui_price_info_object_1 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 249);
            let usdc_price_info_object_1 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 249);
            let deep_price_info_object_1 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 249);

            let mut update_vault_weight_ticket = lp_farm.create_update_vault_weight_ticket<LP_TOKEN, SPAM>();
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault,
                &db_pool,
                &sui_price_info_object_1,
                &usdc_price_info_object_1,
                &deep_price_info_object_1,
                &ag,
                &mut update_vault_weight_ticket,
                &clock,
            );
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault_dummy,
                &db_pool,
                &sui_price_info_object_1,
                &usdc_price_info_object_1,
                &deep_price_info_object_1,
                &ag,
                &mut update_vault_weight_ticket,
                &clock,
            );
            lp_farm.destroy_update_vault_weight_ticket<LP_TOKEN, SPAM>(update_vault_weight_ticket);

            // Farm Total USD value
            // debug::print(&vault.get_total_usd_value<LP_TOKEN, SUI, USDC>(&db_pool, &sui_price_info_object, &usdc_price_info_object, &deep_price_info_object, &ag, &clock));
            debug::print(&lp_farm.get_vault_tvls_sum<LP_TOKEN>());
            assert!(lp_farm.get_vault_tvls_sum<LP_TOKEN>() == 9_540_000_000);

            // -- +50 s --
            set_clock_sec(&mut clock, 300);
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault, &mut top_up_ticket, &clock);

            assert_proximity(vault.get_incentive_value<LP_TOKEN, SPAM>() + vault_spam.value(), 3702, 10);
            let vault_spam_2 = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());
            let mut top_up_ticket_dummy = vault_dummy.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);

            assert_proximity(vault_dummy.get_incentive_value<LP_TOKEN, SPAM>() + vault_dummy_spam.value(), 6298, 10);
            let vault_dummy_spam_2 = vault_dummy.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket_dummy, test.ctx());

            assert_proximity(vault_spam_2.value() + vault_spam.value(), 3702, 10);
            assert_proximity(vault_dummy_spam_2.value() + vault_dummy_spam.value(), 6298, 10);

            // -- +100 s --
            lp_farm.add_banned_vault<LP_TOKEN>(&lp_farm_admin_cap, &vault_dummy);
            let sui_price_info_object_1_1 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 299);
            let usdc_price_info_object_1_1 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 299);
            let deep_price_info_object_1_1 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 299);
            let mut update_vault_weight_ticket = lp_farm.create_update_vault_weight_ticket<LP_TOKEN, SPAM>();
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault,
                &db_pool,
                &sui_price_info_object_1_1,
                &usdc_price_info_object_1_1,
                &deep_price_info_object_1_1,
                &ag,
                &mut update_vault_weight_ticket,
                &clock,
            );
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault_dummy,
                &db_pool,
                &sui_price_info_object_1_1,
                &usdc_price_info_object_1_1,
                &deep_price_info_object_1_1,
                &ag,
                &mut update_vault_weight_ticket,
                &clock,
            );
            lp_farm.destroy_update_vault_weight_ticket<LP_TOKEN, SPAM>(update_vault_weight_ticket);
            set_clock_sec(&mut clock, 400);
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault, &mut top_up_ticket, &clock);
            let vault_spam_3 = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());
            // Banned vault can't be top up
            // let mut top_up_ticket_dummy = vault_dummy.new_top_up_ticket();
            // lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);
            // lp_farm.top_up_to_td_pool<LP_TOKEN, AIRE>(&mut vault_dummy, &mut top_up_ticket_dummy, &clock);
            // lp_farm.collect_incentive_rewards_to_vault<LP_TOKEN, SPAM>(&mut vault_dummy, top_up_ticket_dummy, &clock);

            // debug::print(&vault.get_incentive_value<LP_TOKEN, SPAM>());
            // debug::print(&vault_dummy.get_incentive_value<LP_TOKEN, SPAM>());
            debug::print(&vault_spam_3.value());

            assert!(lp_farm.get_vault_tvls_sum() == (330 * 4 + 300 * 1 + 3060) * 1_000_000);

            // -- Close vault --
            let sui_price_info_object_2 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 399);
            let usdc_price_info_object_2 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 399);
            let deep_price_info_object_2 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 399);

            let (sui, usdc, deep, mut close_vault_ticket) = lp_farm.close_vault_deprecated<LP_TOKEN, SUI, USDC>(
                &mut vault,
                &vault_creator_cap,
                &lotus_config, 
                &db_pool,
                &sui_price_info_object_2, 
                &usdc_price_info_object_2, 
                &deep_price_info_object_2, 
                &ag, 
                &clock, 
                test.ctx()
            );
            lp_farm.remove_farm_key_from_td_farm<LP_TOKEN, SPAM>(
                &mut vault,
                &mut close_vault_ticket,
                &clock,
            );
            lp_farm.remove_farm_key_from_td_farm<LP_TOKEN, AIRE>(
                &mut vault,
                &mut close_vault_ticket,
                &clock,
            );
            lp_farm.destroy_close_vault_ticket(close_vault_ticket);

            debug::print(&sui.balance().value());       // 308.451
            debug::print(&usdc.balance().value());      // 3140.592000
            debug::print(&deep.balance().value());      // 0
            // Performance fee: 1%
            // mint_for_testing<SUI>(330_000_000_000, test.ctx()),
            // mint_for_testing<USDC>(300_000_000, test.ctx()),
            // vault.deposit<USDC, LP_TOKEN>(mint_for_testing<USDC>(3_060_000_000, test.ctx()), test.ctx())
            
            // Cost: 330 * 4 + 300 * 1 = 1620
            // Current: 330 * 4 + 300 * 1 + 3060 = 4680
            // Fee: (4680 - 1620) * 10% = 306
            // Ratio: 306 / 4680 = 0.06538461538461539

            // Redeemed value
            // Program:
            // 308.451 * 4 + 3140.592 * 1 = 4374.396
            // diff: 4374.396 - 4680 = -305.604
            // Expected:
            // Sui:
            // 330 * (1 - 0.06538461538461539) = 308.451
            // Usdc:
            // 300 * (1 - 0.06538461538461539) = 3140.592

            // Collected Fee value
            // SUI: 330 * 0.06538461538461539 = 21.5

            assert_proximity(sui.balance().value(), 308_451_000_000, 10);
            assert_proximity(usdc.balance().value(), 3_140_592_000, 10);
            assert!(deep.balance().value() == 0);

            let fees = vault.withdraw_collected_performance_fees<LP_TOKEN, SUI>(&lotus_config_cap, test.ctx());
            assert_proximity(fees.balance().value(), 21_549_000_000, 10);

            // Expected VaultDummy balance
            // Cost: 990 * 4 + 900 * 1 = 3960
            debug::print(&lp_farm.get_vault_tvls_sum());

            // Clean up
            price_info::destroy(sui_price_info_object);
            price_info::destroy(usdc_price_info_object);
            price_info::destroy(deep_price_info_object);
            price_info::destroy(sui_price_info_object_1);
            price_info::destroy(usdc_price_info_object_1);
            price_info::destroy(deep_price_info_object_1);
            price_info::destroy(sui_price_info_object_1_1);
            price_info::destroy(usdc_price_info_object_1_1);
            price_info::destroy(deep_price_info_object_1_1);
            price_info::destroy(sui_price_info_object_2);
            price_info::destroy(usdc_price_info_object_2);
            price_info::destroy(deep_price_info_object_2);

            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);

            transfer::public_share_object(vault);
            transfer::public_share_object(vault_dummy);
            transfer::public_transfer(vault_creator_cap, user);
            transfer::public_transfer(vault_trade_cap, user);
            transfer::public_transfer(vault_dummy_creator_cap, user);
            transfer::public_transfer(vault_dummy_trade_cap, user);
            transfer::public_share_object(sui);
            transfer::public_share_object(usdc);
            transfer::public_share_object(deep);
            transfer::public_share_object(fees);

            transfer::public_share_object(vault_spam);
            transfer::public_share_object(vault_dummy_spam);
            transfer::public_share_object(vault_spam_2);
            transfer::public_share_object(vault_dummy_spam_2);
            transfer::public_share_object(vault_spam_3);

            return_shared(db_pool);
            return_shared(ag);
            return_to_address(user, ag_cap);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            clock::destroy_for_testing(clock);
        };
        
        end(test);
    }


    #[test]
    public fun test_out_of_range_vault() {
        // OWNER init
        let user = @0xA;
        let delegate = @0xD;
        let spam = 0xEEE;

        let mut test = begin(user);
        
        // Deepbook init
        let registry_id = setup_test(user, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            user,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(user, registry_id, balance_manager_id_alice, &mut test);

        // Farm init
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        // User operations.
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);

            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1000);

            // Farm
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 200, test.ctx());
            lp_farm.add_td_farm<LP_TOKEN, AIRE>(&lp_farm_admin_cap, 200, test.ctx());

            // Test vault USD balance            
            // Price:
            //   - SUI: 4
            //   - USDC: 1
            //   - DEEP: 0.1
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 99);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 99);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 99);
            ag.update_pyth_price_id<SUI>(&ag_cap, sui_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<USDC>(&ag_cap, usdc_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_pyth_price_id<DEEP>(&ag_cap, deep_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_decimal<DEEP>(&ag_cap, 6);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<DEEP>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());

            // -- Vault from farm --
            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(330_000_000_000, test.ctx()),
                mint_for_testing<USDC>(300_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, AIRE>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            let mut update_vault_weight_ticket = lp_farm.create_update_vault_weight_ticket<LP_TOKEN, SPAM>();
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault,
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &ag,
                &mut update_vault_weight_ticket,
                &clock,
            );
            lp_farm.destroy_update_vault_weight_ticket<LP_TOKEN, SPAM>(update_vault_weight_ticket);

            // Set strategy params in range
            // 10^(9 + quote_decimals - base_decimals)
            // Upper price: 4 * 10^(9 + 6 - 9) = 4_000_000
            vault.update_strategy_params(&vault_creator_cap, utf8(b"strategy_type"), 1);

            vault.update_strategy_params(&vault_creator_cap, utf8(b"upper"), 4_100_000);
            vault.update_strategy_params(&vault_creator_cap, utf8(b"lower"), 3_000_000);
            vault.update_strategy_params(&vault_creator_cap, utf8(b"n-levels"), 10);
            vault.update_strategy_params(&vault_creator_cap, utf8(b"size"), 1_000_000_000);
            
            assert!(vault.is_strategy_in_range(&db_pool, &sui_price_info_object, &usdc_price_info_object, &ag, &clock));
            // Set strategy params out of range, assert update weight oor
            vault.update_strategy_params(&vault_creator_cap, utf8(b"upper"), 3_900_000);
            assert!(!vault.is_strategy_in_range(&db_pool, &sui_price_info_object, &usdc_price_info_object, &ag, &clock));
            lp_farm.update_zero_weight_oor_vault<LP_TOKEN, SPAM, SUI, USDC>(&vault, &db_pool, &sui_price_info_object, &usdc_price_info_object, &ag, &clock);

            // Clean up
            price_info::destroy(sui_price_info_object);
            price_info::destroy(usdc_price_info_object);
            price_info::destroy(deep_price_info_object);

            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);

            transfer::public_share_object(vault);
            transfer::public_transfer(vault_creator_cap, user);
            transfer::public_transfer(vault_trade_cap, user);

            return_shared(db_pool);
            return_shared(ag);
            return_to_address(user, ag_cap);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            clock::destroy_for_testing(clock);
        };
        
        end(test);
    }
    

    // #[test]
    // public fun test_calc_usd_value() {
    //     // OWNER init
    //     let user = @0xA;
    //     let delegate = @0xD;
    //     let spam = 0xEEE;

    //     let mut test = begin(user);
        
    //     // Deepbook init
    //     let registry_id = setup_test(user, &mut test);
    //     let balance_manager_id_alice = create_acct_and_share_with_funds(
    //         user,
    //         1000000 * constants::float_scaling(),
    //         &mut test,
    //     );
    //     let pool_id = setup_pool<
    //         DEEP,
    //         SUI,
    //     >(user, registry_id, true, false, &mut test);

    //     // Farm init
    //     let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

    //     // User operations.
    //     test.next_tx(user);
    //     oracle_ag::init_test(test.ctx());
    //     test.next_tx(user);
    //     {
    //         let mut clock = create_clock_at_sec(100, test.ctx());
    //         let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
    //         let db_pool_id = object::id(&db_pool);

    //         let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
    //         let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());

    //         // Farm
    //         let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
    //         let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
    //         lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
    //         lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
    //         lp_farm.add_allowed_db_pool<LP_TOKEN>(&lp_farm_admin_cap, db_pool_id);

    //         lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 200, test.ctx());
    //         lp_farm.add_td_farm<LP_TOKEN, AIRE>(&lp_farm_admin_cap, 200, test.ctx());

    //         // Base: SUI, Quote: USDC
    //         let base_scale = 1_000_000_000;
    //         let quote_scale = 1_000_000;
    //         let deep_scale = 1_000_000;

    //         // Test vault USD balance            
    //         // Price:
    //         //   - SUI: 4
    //         //   - USDC: 1
    //         //   - DEEP: 0.1
    //         let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 99);
    //         let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 99);
    //         let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 99);
    //         ag.update_pyth_price_id<SUI>(&ag_cap, sui_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
    //         ag.update_pyth_price_id<USDC>(&ag_cap, usdc_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
    //         ag.update_pyth_price_id<DEEP>(&ag_cap, deep_price_info_object.get_price_info_from_price_info_object().get_price_identifier().get_bytes());
    //         ag.update_coin_decimal<SUI>(&ag_cap, 9);
    //         ag.update_coin_decimal<USDC>(&ag_cap, 6);
    //         ag.update_coin_decimal<DEEP>(&ag_cap, 6);

    //         // -- Vault from farm --
    //         let (mut vault, vault_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, USDC>(
    //             db_pool_id,
    //             mint_for_testing<USDC>(300_000_000, test.ctx()),
    //             &ag,
    //             &usdc_price_info_object,
    //             &clock,
    //             test.ctx(),
    //         );
    //         lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
    //         lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, AIRE>(&mut vault, &mut create_vault_ticket, &clock);
    //         lp_farm.destroy_create_pool_ticket(create_vault_ticket);


    //         // Clean up
    //         price_info::destroy(sui_price_info_object);
    //         price_info::destroy(usdc_price_info_object);
    //         price_info::destroy(deep_price_info_object);

    //         test_scenario::return_shared(lp_farm);
    //         test_scenario::return_to_sender(&test, lp_farm_admin_cap);

    //         transfer::public_share_object(vault);
    //         transfer::public_transfer(vault_cap, user);
    //         return_shared(db_pool);
    //         return_shared(ag);
    //         return_to_address(user, ag_cap);
    //         clock::destroy_for_testing(clock);
    //     };
        
    //     end(test);
    // }
    
}