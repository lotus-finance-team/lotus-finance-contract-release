module lotus_finance::lotus_db_vault_pooling_tests {
    use std::debug;
    use std::string::{Self as STD_STRING};
    use std::type_name::{Self, TypeName};
    use sui::sui::SUI;
    use sui::vec_set::{Self, VecSet};
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
    use lotus_finance::lotus_config::{Self, LotusConfig, LotusConfigCap};
    use lotus_finance::lotus_math::{mul, div};
    use lotus_finance::test_utils::{create_clock_at_sec, build_pyth_price_info_object, MY_SUI, MY_DEEP, set_clock_sec, setup_lotus_lp_farm, assert_proximity, build_demo_sui_price_info_object, build_demo_usdc_price_info_object};
    use lotus_finance::lotus_vault_db_related_tests::{Self, setup_test, setup_pool_with_default_fees_and_reference_pool, create_acct_and_share_with_funds};
    use sui::table;
    use sui::borrow::Test;
    use deepbook::vault;

    const OWNER: address = @0x1;

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

    #[test]
    fun test_pooling_walkthrough() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAAAA;
        let bob = @0xBBBB;
        let charlie = @0xCCCC;
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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        //---- 1: Farm and Vault setup, initial deposit ----//
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            // -- 1. User deposit -- //
            // -- 1.1. -- //
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 600);   // 9%
            lotus_config.update_strategy_fee_bps(&lotus_config_cap, 400);      // 1%
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());

            // 1. Create Pool
            // 2. Pooling user Alice deposit
            // 2.1 Pooling user Bob deposit
            // 3. Place orders
            // 4. Pooling user withdraw
            
            // Test case 1
            // Price:
            //   - SUI: 4
            //   - USDC: 1
            //   - DEEP: 0.1
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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(110_000_000_000, test.ctx()),
                mint_for_testing<USDC>(130_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            let (user_share, total_share) = vault.get_user_and_total_shares(user);
            debug::print(&user_share);
            debug::print(&total_share);
            assert!(user_share == (110 * 4 + 130) * 1_000_000);
            assert!(total_share == user_share);
            assert!(vault.get_user_cost(user) == user_share);
            
            let coin: Coin<SPAM> = mint_for_testing<SPAM>(100_000_000_000, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, SPAM>(coin, &clock);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 100, &clock, test.ctx());

            // vault.deposit<SUI, LP_TOKEN>(mint_for_testing<SUI>(100_000_000_000, test.ctx()), test.ctx());
            vault.claim_rebates_test<LP_TOKEN, SUI, USDC, SUI>(&mut db_pool, mint_for_testing<SUI>(7, test.ctx()), test.ctx());
            vault.claim_rebates_test<LP_TOKEN, SUI, USDC, USDC>(&mut db_pool, mint_for_testing<USDC>(1, test.ctx()), test.ctx());
            vault.claim_rebates_test<LP_TOKEN, SUI, USDC, DEEP>(&mut db_pool, mint_for_testing<DEEP>(113, test.ctx()), test.ctx());

            // -- 1.2. -- //
            set_clock_sec(&mut clock, 1300);
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            // lp_farm.collect_incentive_rewards_to_vault<LP_TOKEN, SPAM>(&mut vault, top_up_ticket, &clock);
            // Assert withdrawable incentive
            assert_proximity(vault.get_incentive_value<LP_TOKEN, SPAM>(), 100 * 100, 10);
            assert_proximity(vault.get_incentive_value_for_user<LP_TOKEN, SPAM>(user), 100 * 100, 10);
            let vault_incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());
            debug::print(&vault_incentive.value());
            assert_proximity(vault_incentive.value(), 100 * 100, 10);

            // -- 1.3. -- //
            vault.stake<LP_TOKEN, SUI, USDC>(
                &vault_creator_cap,
                &mut db_pool,
                mint_for_testing<DEEP>(100_000_000_000, test.ctx()),
                test.ctx(),
            );

            vault.claim_rebates_permissionless(&mut db_pool, test.ctx());

            let mut ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut ticket, &clock);
            let incentive_coin = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(ticket, test.ctx());

            transfer::public_share_object(incentive_coin);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_incentive);
            transfer::public_transfer(vault_creator_cap, test.sender());
            transfer::public_share_object(vault_trade_cap);
            return_shared(db_pool);
            return_shared(ag);
            return_to_address(user, ag_cap);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            clock::destroy_for_testing(clock);
        };

        test.next_tx(alice);
        {
            // -- 2. Alice Ops -- //
            // -- 2.1. -- //
            let mut clock = create_clock_at_sec(1300, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1299);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1299);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1299);
            
            let total_shares_before_alice = vault.get_total_shares();
            debug::print(&total_shares_before_alice);
            let total_value_before_alice = vault.get_total_usd_value<LP_TOKEN, SUI, USDC>(&db_pool, &sui_price_info_object, &usdc_price_info_object, &deep_price_info_object, &oracle_ag, &clock);
            debug::print(&total_value_before_alice);

            // Pooling deposit
            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(5_200_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            let vault_usd_value = vault.get_total_usd_value<LP_TOKEN, SUI, USDC>(&db_pool, &sui_price_info_object, &usdc_price_info_object, &deep_price_info_object, &oracle_ag, &clock);
            assert!(vault_usd_value == (110 * 3 + 130 + 100 * 3 + 5_200) * 1_000_000);
            assert!(vault.get_user_cost(alice) == (100 * 3 + 5200) * 1_000_000);
            assert!(vault.get_user_cost(user) == (110 * 4 + 130) * 1_000_000);
            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);
            // Target alice share = total shares / vault usd value * alice usd value
            let target_alice_share = total_shares_before_alice * (100 * 3 + 5200) * 1_000_000 / total_value_before_alice;
            assert!(alice_shares == target_alice_share);

            // Incentives
            //   - Update vault weight
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let mut update_vault_weight_ticket = lp_farm.create_update_vault_weight_ticket<LP_TOKEN, SPAM>();
            lp_farm.update_vault_weight_with_ticket<LP_TOKEN, SPAM, SUI, USDC>(
                &vault, 
                &db_pool, 
                &sui_price_info_object, 
                &usdc_price_info_object, 
                &deep_price_info_object, 
                &oracle_ag, 
                &mut update_vault_weight_ticket,
                &clock
            );
            lp_farm.destroy_update_vault_weight_ticket<LP_TOKEN, SPAM>(update_vault_weight_ticket);
            //   - Collect incentive rewards to vault, assert vault SPAM balance
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            // let alice_incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(test.ctx());
            let alice_incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());

            debug::print(&STD_STRING::utf8(b"Alice incentive:"));
            debug::print(&alice_incentive.value());
            debug::print(&target_alice_share);
            debug::print(&total_shares);
            assert!(alice_incentive.value() == 0);

            // -- 2.2. -- //
            // Wait 100 seconds for 100 * 100 incentives to be distributed
            set_clock_sec(&mut clock, 1400);

            let mut top_up_ticket = vault.new_top_up_ticket();
            // Before top up incentive should be fewer
            let expected_alice_incentive = 100 * 100 * target_alice_share / total_shares;
            assert!(vault.get_incentive_value_for_user<LP_TOKEN, SPAM>(alice) < expected_alice_incentive);
            assert!(vault.get_incentive_value<LP_TOKEN, SPAM>() < 100 * 100);
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            assert_proximity(vault.get_incentive_value_for_user<LP_TOKEN, SPAM>(alice), expected_alice_incentive, 10);
            let alice_incentive_2 = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());
            assert_proximity(alice_incentive_2.value(), expected_alice_incentive, 10);

            let total_shares_before_alice_withdraw = vault.get_total_shares();
            // -- 2.3. Alice Pooling withdraw -- //
            let sui_price_info_object_2 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1399);
            let usdc_price_info_object_2 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1399);
            let deep_price_info_object_2 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1399);
            let (sui_balance, usdc_balance) = vault.pooling_withdraw<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &mut db_pool,
                &sui_price_info_object_2,
                &usdc_price_info_object_2,
                &deep_price_info_object_2,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            debug::print(&STD_STRING::utf8(b"Alice Withdraw balance:"));
            debug::print(&sui_balance.value());
            debug::print(&STD_STRING::utf8(b"USDC Withdraw balance:"));
            debug::print(&usdc_balance.value());
            // Expected total USD value: alice_shares / total_shares * vault_usd_amount * (1 - performance_fee_ratio)
            assert_proximity(usdc_balance.value(), 4901_883_332, 200);
            assert_proximity(sui_balance.value(), 193_132_363_791, 2000);
            // assert!(&usdc_balance.value() == expected_withdraw_usd_value - expected_withdraw_usd_value);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(sui_price_info_object_2);
            transfer::public_share_object(usdc_price_info_object_2);
            transfer::public_share_object(deep_price_info_object_2);
            transfer::public_share_object(sui_balance);
            transfer::public_share_object(usdc_balance);
            transfer::public_share_object(alice_incentive);
            transfer::public_share_object(alice_incentive_2);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };

        test.next_tx(alice);
        {
            // -- 3. Alice Ops -- //
            // -- 3.1. -- //
            let mut clock = create_clock_at_sec(1500, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1499);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1499);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1499);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);

            let vault_sui_amount = vault.get_total_balance<LP_TOKEN, SUI, SUI, USDC>(&db_pool);
            assert_proximity(vault_sui_amount, 16208053691, 10);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_200_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);  
            let alice_cost = vault.get_user_cost(alice);
            let usdc_amount_after = vault.get_total_balance<LP_TOKEN, USDC, SUI, USDC>(&db_pool);
            debug::print(&STD_STRING::utf8(b"Alice shares 2nd deposit:"));
            debug::print(&alice_shares);
            debug::print(&STD_STRING::utf8(b"Alice Cost 2nd deposit:"));
            debug::print(&alice_cost);

            assert_proximity(alice_cost, 2600 * 1_000_000, 10);
            assert_proximity(alice_shares, 3_112_085_130, 10);
            assert_proximity(usdc_amount_after, 2_611_375_838, 10);

            // -- 3.2 -- //
            set_clock_sec(&mut clock, 1600);

            let sui_price_info_object_2 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 5_000_000_000, 1, 9, 1599);
            let usdc_price_info_object_2 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1599);
            let deep_price_info_object_2 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1599);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_100_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object_2,
                &usdc_price_info_object_2,
                &deep_price_info_object_2,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);
            let alice_cost = vault.get_user_cost(alice);
            debug::print(&STD_STRING::utf8(b"Alice shares 2nd deposit:"));
            debug::print(&alice_shares);
            assert_proximity(alice_cost, 5200 * 1_000_000, 10);
            assert_proximity(alice_shares, 6_110_886_358, 10);

            let usdc_amount_after = vault.get_total_balance<LP_TOKEN, USDC, SUI, USDC>(&db_pool);
            assert_proximity(usdc_amount_after, 4_711_375_838, 10);

            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(sui_price_info_object_2);
            transfer::public_share_object(usdc_price_info_object_2);
            transfer::public_share_object(deep_price_info_object_2);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };

        test.next_tx(charlie);
        {
            // -- 4. Charlie Ops -- //
            // -- 4.1. -- //
            let mut clock = create_clock_at_sec(1700, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 6_000_000_000, 1, 9, 1699);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1699);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1699);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);

            // Pooling deposit
            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_300_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            let (charlie_shares, total_shares) = vault.get_user_and_total_shares(charlie);            
            assert_proximity(charlie_shares, 3_224_460_362, 10);
            assert_proximity(total_shares, 3_224_460_362 + 6_110_886_358 + 570_000_000, 10);
            let usdc_amount_after = vault.get_total_balance<LP_TOKEN, USDC, SUI, USDC>(&db_pool);
            assert_proximity(usdc_amount_after, 7_011_375_838, 10);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };

        test.next_tx(alice);
        {
            // -- 5. Alice Ops -- //
            let mut clock = create_clock_at_sec(1800, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 7_000_000_000, 1, 9, 1799);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1799);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1799);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            
            // -- 5.1. -- //
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            let alice_incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());
            debug::print(&STD_STRING::utf8(b"5.1 Alice incentive:"));
            debug::print(&alice_incentive.value());

            // -- 5.2 -- //
            let (sui_balance, usdc_balance) = vault.pooling_withdraw<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &mut db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );
            debug::print(&STD_STRING::utf8(b"5.2 Alice Withdraw balance:"));
            debug::print(&sui_balance.value());
            assert_proximity(sui_balance.value(), 193_394_378_966, 10);
            debug::print(&STD_STRING::utf8(b"5.2 USDC Withdraw balance:"));
            debug::print(&usdc_balance.value());
            assert_proximity(usdc_balance.value(), 4_288_191_462, 10);


            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(alice_incentive);
            transfer::public_share_object(sui_balance);
            transfer::public_share_object(usdc_balance);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);

        };

        test.next_tx(user);
        {
            // -- 6. Close Vault -- //
            // -- 6.1. -- User withdraw //
            let mut clock = create_clock_at_sec(1900, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let vault_creator_cap = test.take_from_sender<LotusDBVaultCap>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 1899);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1899);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1899);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            let incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());

            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            vault.admin_distribute_incentive_to_pooling_user_on_purge_direct<LP_TOKEN, SUI>(&lotus_config_cap, test.sender(), test.ctx());
            vault.admin_distribute_incentive_to_pooling_user_on_purge_direct<LP_TOKEN, USDC>(&lotus_config_cap, test.sender(), test.ctx());
            vault.admin_distribute_incentive_to_pooling_user_on_purge_direct<LP_TOKEN, DEEP>(&lotus_config_cap, test.sender(), test.ctx());
            return_to_address(user, lotus_config_cap);

            let (sui_balance, usdc_balance) = vault.pooling_withdraw<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &mut db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            let unstaked_deep = vault.unstake(&vault_creator_cap, &mut db_pool, test.ctx());
            assert!(unstaked_deep.value() == 100_000_000_000);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(sui_balance);
            transfer::public_share_object(usdc_balance);
            transfer::public_share_object(incentive);
            transfer::public_share_object(unstaked_deep);
            return_shared(vault);
            return_to_address(test.sender(), vault_creator_cap);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };
        
        test.next_tx(user);
        {
            // -- 6. Close Vault -- //
            // -- 6.2. -- Admin withdraw for Charlie //
            let mut clock = create_clock_at_sec(2000, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 1999);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1999);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1999);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            vault.admin_distribute_incentive_to_pooling_user_on_purge<LP_TOKEN, SPAM>(
                &lotus_config_cap,
                charlie,
                top_up_ticket,
                test.ctx(),
            );

            // Distribute tokens
            vault.admin_distribute_tokens_to_pooling_user_on_purge<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &lotus_config_cap,
                &mut db_pool,
                charlie,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };
        
        test.next_tx(user);
        {
            // -- 6. Close Vault -- //
            // -- 6.3. -- Admin close vault //
            let mut clock = create_clock_at_sec(2100, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 2099);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 2099);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 2099);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            
            let mut close_vault_ticket = lp_farm.close_vault_permissionless<LP_TOKEN>(&vault);
            lp_farm.remove_farm_key_from_td_farm<LP_TOKEN, SPAM>(&mut vault, &mut close_vault_ticket, &clock);
            lp_farm.destroy_close_vault_ticket(close_vault_ticket);

            let sui_left_amount = vault.get_total_balance<LP_TOKEN, SUI, SUI, USDC>(&db_pool);
            assert!(sui_left_amount == 0);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };
        
        end(test);
    }

    

    #[test]
    fun test_pooling_numerics_n1() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAAAA;
        let bob = @0xBBBB;
        let charlie = @0xCCCC;
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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 600);   // 9%
            lotus_config.update_strategy_fee_bps(&lotus_config_cap, 400);      // 1%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 30 * 1000); // 30s
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1000);
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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(100_000_000_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(user, lotus_config_cap);
            test_scenario::return_to_address(user, ag_cap);
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_address(user, lp_farm_admin_cap);
            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };


        test.next_tx(alice);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();

            let mut i = 0;
            while (i < 10) {
                let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1000 + 50 * i);
                let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000 + 50 * i);
                let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000 + 50 * i);
                set_clock_sec(&mut clock, 1000 + 50 * i);

                vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                    mint_for_testing<USDC>(100_000_000, test.ctx()),
                    &db_pool,
                    &sui_price_info_object,
                    &usdc_price_info_object,
                    &deep_price_info_object,
                    &ag,
                    &clock,
                    test.ctx(),
                );

                // Clean up
                transfer::public_share_object(sui_price_info_object);
                transfer::public_share_object(usdc_price_info_object);
                transfer::public_share_object(deep_price_info_object);

                i = i + 1;
            };

            // User shares, User cost, expected: 100_000 * 3 + 1_000_000 * 1 = 1_300_000
            let (user_shares, total_shares) = vault.get_user_and_total_shares(user);
            let user_cost = vault.get_user_cost(user);
            debug::print(&STD_STRING::utf8(b"User shares:"));
            debug::print(&user_shares);
            assert_proximity(user_shares, 1_300_000 * 1_000_000, 10);
            assert_proximity(user_cost, 1_300_000 * 1_000_000, 10);

            // Alice shares, Alice cost, expected: (100 * 3 + 100 * 1) * 10 = 4_000
            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);
            let alice_cost = vault.get_user_cost(alice);
            debug::print(&STD_STRING::utf8(b"Alice shares:"));
            debug::print(&alice_shares);
            assert_proximity(alice_shares, 4_000 * 1_000_000, 10);
            assert_proximity(alice_cost, 4_000 * 1_000_000, 10);

            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_shared(vault);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        end(test);
    }


    #[test]
    fun test_pooling_numerics_n1_1() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAAAA;
        let bob = @0xBBBB;
        let charlie = @0xCCCC;
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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 600);   // 9%
            lotus_config.update_strategy_fee_bps(&lotus_config_cap, 400);      // 1%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 30 * 1000); // 30s
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1000);
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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(100_000_000_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(user, lotus_config_cap);
            test_scenario::return_to_address(user, ag_cap);
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_address(user, lp_farm_admin_cap);
            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };


        test.next_tx(alice);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();

            let mut i = 0;
            while (i < 10) {
                let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1000 + 100 * i);
                let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000 + 100 * i);
                let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000 + 100 * i);
                set_clock_sec(&mut clock, 1000 + 100 * i);

                vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                    mint_for_testing<USDC>(100_000_000, test.ctx()),
                    &db_pool,
                    &sui_price_info_object,
                    &usdc_price_info_object,
                    &deep_price_info_object,
                    &ag,
                    &clock,
                    test.ctx(),
                );

                transfer::public_share_object(sui_price_info_object);
                transfer::public_share_object(usdc_price_info_object);
                transfer::public_share_object(deep_price_info_object);
                let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 3_000_000_000, 1, 9, 1000 + 100 * i + 50);
                let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000 + 100 * i + 50);
                let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000 + 100 * i + 50);


                set_clock_sec(&mut clock, 1000 + 100 * i + 50);

                let (coin_base, coin_quote) = vault.pooling_withdraw(
                    &lotus_config,
                    &mut db_pool,
                    &sui_price_info_object,
                    &usdc_price_info_object,
                    &deep_price_info_object,
                    &ag,
                    &clock,
                    test.ctx(),
                );

                // Clean up
                transfer::public_share_object(coin_base);
                transfer::public_share_object(coin_quote);
                transfer::public_share_object(sui_price_info_object);
                transfer::public_share_object(usdc_price_info_object);
                transfer::public_share_object(deep_price_info_object);

                i = i + 1;
            };

            // User shares, User cost, expected: 100_000 * 3 + 1_000_000 * 1 = 1_300_000
            let (user_shares, total_shares) = vault.get_user_and_total_shares(user);
            let user_cost = vault.get_user_cost(user);
            debug::print(&STD_STRING::utf8(b"User shares:"));
            debug::print(&user_shares);
            assert_proximity(user_shares, 1_300_000 * 1_000_000, 10);
            assert_proximity(user_cost, 1_300_000 * 1_000_000, 10);

            // Alice shares, Alice cost, expected: (100 * 3 + 100 * 1) * 10 = 4_000
            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);
            let alice_cost = vault.get_user_cost(alice);
            debug::print(&STD_STRING::utf8(b"Alice shares:"));
            debug::print(&alice_shares);
            assert!(alice_shares == 0);
            assert!(alice_cost == 0);

            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_shared(vault);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        end(test);
    }

    #[test]
    fun test_pooling_numerics_n2() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAAAA;
        let bob = @0xBBBB;
        let charlie = @0xCCCC;
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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 600);   // 9%
            lotus_config.update_strategy_fee_bps(&lotus_config_cap, 400);      // 1%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 30 * 1000); // 30s
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());
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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(100_000_000_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(user, lotus_config_cap);
            test_scenario::return_to_address(user, ag_cap);
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_address(user, lp_farm_admin_cap);
            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };


        test.next_tx(alice);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();

            let mut i = 0;
            while (i < 20) {
                let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 1000 + 100 * i);
                let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000 + 100 * i);
                let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000 + 100 * i);
                set_clock_sec(&mut clock, 1000 + 100 * i);

                vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                    mint_for_testing<USDC>(100_000_000, test.ctx()),
                    &db_pool,
                    &sui_price_info_object,
                    &usdc_price_info_object,
                    &deep_price_info_object,
                    &ag,
                    &clock,
                    test.ctx(),
                );

                transfer::public_share_object(sui_price_info_object);
                transfer::public_share_object(usdc_price_info_object);
                transfer::public_share_object(deep_price_info_object);
                let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 2_000_000_000, 1, 9, 1000 + 100 * i + 50);
                let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1000 + 100 * i + 50);
                let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1000 + 100 * i + 50);


                set_clock_sec(&mut clock, 1000 + 100 * i + 50);

                let (coin_base, coin_quote) = vault.pooling_withdraw(
                    &lotus_config,
                    &mut db_pool,
                    &sui_price_info_object,
                    &usdc_price_info_object,
                    &deep_price_info_object,
                    &ag,
                    &clock,
                    test.ctx(),
                );

                // Clean up
                transfer::public_share_object(coin_base);
                transfer::public_share_object(coin_quote);
                transfer::public_share_object(sui_price_info_object);
                transfer::public_share_object(usdc_price_info_object);
                transfer::public_share_object(deep_price_info_object);

                i = i + 1;
            };

            // User shares, User cost, expected: 100_000 * 3 + 1_000_000 * 1 = 1_300_000
            let (user_shares, total_shares) = vault.get_user_and_total_shares(user);
            let user_cost = vault.get_user_cost(user);
            debug::print(&STD_STRING::utf8(b"User shares:"));
            debug::print(&user_shares);
            assert_proximity(user_shares, 1_400_000 * 1_000_000, 10);
            assert_proximity(user_cost, 1_400_000 * 1_000_000, 10);

            // Alice shares, Alice cost, expected: (100 * 3 + 100 * 1) * 10 = 4_000
            let (alice_shares, total_shares) = vault.get_user_and_total_shares(alice);
            let alice_cost = vault.get_user_cost(alice);
            debug::print(&STD_STRING::utf8(b"Alice shares:"));
            debug::print(&alice_shares);
            assert!(alice_shares == 0);
            assert!(alice_cost == 0);

            // Print vault tokens
            debug::print(&STD_STRING::utf8(b"Vault tokens SUI:"));
            debug::print(&vault.get_total_balance<LP_TOKEN, SUI, SUI, USDC>(&db_pool));
            debug::print(&STD_STRING::utf8(b"Vault tokens USDC:"));
            debug::print(&vault.get_total_balance<LP_TOKEN, USDC, SUI, USDC>(&db_pool));

            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_shared(vault);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        end(test);
    }


    #[test]
    fun test_pooling_fees() {
        // OWNER init
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAAAA;
        
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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1000, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1_300);   // 13%
            lotus_config.update_strategy_fee_bps(&lotus_config_cap, 1_700);      // 17%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 30 * 1000); // 30s
            lotus_config.update_early_withdrawal_fee_bps(&lotus_config_cap, 80); // 0.8%
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());
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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(100_000_000_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(user, lotus_config_cap);
            test_scenario::return_to_address(user, ag_cap);
            transfer::public_share_object(vault);
            transfer::public_transfer(vault_creator_cap, user);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_address(user, lp_farm_admin_cap);
            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };


        test.next_tx(alice);
        {
            let mut clock = create_clock_at_sec(1100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();

            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1100);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1100);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1100);
            set_clock_sec(&mut clock, 1100);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(200_000_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_000_000_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &ag,
                &clock,
                test.ctx(),
            );

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);


            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_shared(vault);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1300, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let ag = test.take_shared<oracle_ag::OracleAggregator>();
            let lotus_config = test.take_shared<LotusConfig>();
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();

            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 1300);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1300);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1300);
            set_clock_sec(&mut clock, 1300);

            let (coin_base, coin_quote) = vault.pooling_withdraw(
                &lotus_config,
                &mut db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &ag,
                &clock,
                test.ctx(),
            );

            debug::print(&STD_STRING::utf8(b"Coin base value:"));
            debug::print(&coin_base.value());
            assert_proximity(coin_base.value(), 92_586_666_666_666, 10_000_000);

            // Clean up
            transfer::public_share_object(coin_base);
            transfer::public_share_object(coin_quote);
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);


            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_shared(vault);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1400, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let ag = test.take_shared<oracle_ag::OracleAggregator>();
            let lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let vault_creator_cap = test.take_from_address<LotusDBVaultCap>(user);

            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 8_000_000_000, 1, 9, 1400);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1400);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1400);
            set_clock_sec(&mut clock, 1400);

            let performance_fee_base = vault.withdraw_collected_performance_fees<LP_TOKEN, SUI>(&lotus_config_cap, test.ctx());
            let performance_fee_quote = vault.withdraw_collected_performance_fees<LP_TOKEN, USDC>(&lotus_config_cap, test.ctx());

            let strategy_fee_base = vault.withdraw_collected_strategy_fees<LP_TOKEN, SUI>(&vault_creator_cap, test.ctx());
            let strategy_fee_quote = vault.withdraw_collected_strategy_fees<LP_TOKEN, USDC>(&vault_creator_cap, test.ctx());

            assert_proximity(performance_fee_base.value(), 2_888_888_888_888 + 746_666_666_666, 1_000_000);
            assert_proximity(performance_fee_quote.value(), 28_888_888_888 + 7_466_666_666, 10_000);
            assert_proximity(strategy_fee_base.value(), 3_777_777_777_777, 1_000_000);
            assert_proximity(strategy_fee_quote.value(), 37_777_777_777, 10_000);

            transfer::public_share_object(performance_fee_base);
            transfer::public_share_object(performance_fee_quote);
            transfer::public_share_object(strategy_fee_base);
            transfer::public_share_object(strategy_fee_quote);

            vault.admin_distribute_tokens_to_pooling_user_on_purge(
                &lotus_config,
                &lotus_config_cap,
                &mut db_pool,
                alice,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &ag,
                &clock,
                test.ctx(),
            );

            let performance_fee_base = vault.withdraw_collected_performance_fees<LP_TOKEN, SUI>(&lotus_config_cap, test.ctx());
            let performance_fee_quote = vault.withdraw_collected_performance_fees<LP_TOKEN, USDC>(&lotus_config_cap, test.ctx());

            let strategy_fee_base = vault.withdraw_collected_strategy_fees<LP_TOKEN, SUI>(&vault_creator_cap, test.ctx());
            let strategy_fee_quote = vault.withdraw_collected_strategy_fees<LP_TOKEN, USDC>(&vault_creator_cap, test.ctx());

            assert_proximity(performance_fee_base.value(), 5_777_777_777_777, 2_000_000);
            assert_proximity(performance_fee_quote.value(), 57_777_777_777, 20_000);
            assert_proximity(strategy_fee_base.value(), 7_555_555_555_555, 2_000_000);
            assert_proximity(strategy_fee_quote.value(), 75_555_555_555, 20_000);

            // Clean up
            transfer::public_share_object(performance_fee_base);
            transfer::public_share_object(performance_fee_quote);
            transfer::public_share_object(strategy_fee_base);
            transfer::public_share_object(strategy_fee_quote);
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);

            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(user, lotus_config_cap);
            test_scenario::return_shared(vault);
            test_scenario::return_to_address(user, vault_creator_cap);

            test_scenario::return_shared(db_pool);
            clock::destroy_for_testing(clock);
    
        };

        end(test);
    }


    #[test, expected_failure(abort_code = lotus_finance::lotus_db_vault::EOperationColdDown)]
    fun test_pooling_user_colddown() {
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAA;

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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        //---- 1: Farm and Vault setup, initial deposit ----//
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1001, test.ctx());
            let db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1000);   // 10%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 1000 * 200); // 200 s
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());

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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(110_000_000_000, test.ctx()),
                mint_for_testing<USDC>(130_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            return_shared(db_pool);
            return_shared(ag);
            return_to_address(user, ag_cap);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            clock::destroy_for_testing(clock);
        };


        test.next_tx(alice);
        {
            // -- 3. Alice Ops -- //
            // -- 3.1. -- //
            let mut clock = create_clock_at_sec(1500, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1499);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1499);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1499);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);

            let vault_sui_amount = vault.get_total_balance<LP_TOKEN, SUI, SUI, USDC>(&db_pool);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_200_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            // -- 3.2 -- //
            set_clock_sec(&mut clock, 1600);

            let sui_price_info_object_2 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 5_000_000_000, 1, 9, 1599);
            let usdc_price_info_object_2 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1599);
            let deep_price_info_object_2 = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1599);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_100_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object_2,
                &usdc_price_info_object_2,
                &deep_price_info_object_2,
                &oracle_ag,
                &clock,
                test.ctx(),
            );


            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(sui_price_info_object_2);
            transfer::public_share_object(usdc_price_info_object_2);
            transfer::public_share_object(deep_price_info_object_2);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };

        end(test);
    }

    #[test]
    fun test_modify_orders_on_withdraw() {
        let mut test = begin(OWNER);
        let user = @0xA;
        let alice = @0xAA;

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

        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, user);

        //---- 1: Farm and Vault setup, initial deposit ----//
        test.next_tx(user);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        test.next_tx(user);
        {
            let mut clock = create_clock_at_sec(1001, test.ctx());
            let db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let db_pool_id = object::id(&db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1000);   // 10%
            lotus_config.update_cold_down_ms(&lotus_config_cap, 1000 * 200); // 200 s
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_db_pool(&lp_farm_admin_cap, &db_pool);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);

            lp_farm.add_td_farm<LP_TOKEN, SPAM>(&lp_farm_admin_cap, 1200, test.ctx());

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

            let (mut vault, vault_creator_cap, vault_trade_cap, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(110_000_000_000, test.ctx()),
                mint_for_testing<USDC>(130_000_000, test.ctx()),
                &ag,
                &sui_price_info_object,
                &usdc_price_info_object,
                &clock,
                test.ctx(),
            );
            vault.deposit(mint_for_testing<DEEP>(1_000_000_000_000, test.ctx()), test.ctx());

            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, SPAM>(&mut vault, &mut create_vault_ticket, &clock);
            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            transfer::public_share_object(vault);
            transfer::public_transfer(vault_trade_cap, user);
            transfer::public_share_object(vault_creator_cap);
            return_shared(db_pool);
            return_shared(ag);
            return_to_address(user, ag_cap);
            return_shared(lotus_config);
            return_to_address(user, lotus_config_cap);
            clock::destroy_for_testing(clock);
        };

        //---- 2: Alice deposit ----//
        test.next_tx(alice);
        {
            let mut clock = create_clock_at_sec(1500, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 4_000_000_000, 1, 9, 1499);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1499);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1499);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);

            vault.pooling_deposit<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                mint_for_testing<SUI>(100_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_200_000_000, test.ctx()),
                &db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);
        };

        //---- 3: User place order ----//
        test.next_tx(user);
        {
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let vault_cap = test.take_from_address<LotusDBVaultCap>(test.sender());
            let mut clock = create_clock_at_sec(1600, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);

            // Place order
            // - Parameters
            //   - Total quote (USDC) = 2_200_000_000
            //   - const LOT_SIZE: u64 = 1_000;
            //   - const MIN_SIZE: u64 = 10_000;
            //   - const TICK_SIZE: u64 = 1_000;
            // - Place order
            //   - price: 1
            //     - native: 10^(9 + 6 - 9) = 1_000_000
            //   - size: (sum up to 2_200) 0.01, 1, 10, 100, 2_088.99
            //     - native: 10_000, 1_000_000, 10_000_000, 100_000_000, 2_088_990_000
            //   - is_bid: true
            let size_vec = vector[10_000_000, 1_000_000_000, 10_000_000_000, 100_000_000_000, 2_088_990_000_000]; // 3_088_990_000_000 would raise EBalanceManagerBalanceTooLow
            
            let mut i = 0;
            while (i < size_vec.length()) {
                debug::print(&STD_STRING::utf8(b"Placing order:"));
                debug::print(&size_vec[i]);
                let size = size_vec[i];
                vault.place_limit_order(
                    &vault_cap,
                    &mut db_pool,
                    111,
                    constants::no_restriction(),
                    constants::self_matching_allowed(),
                    1_000_000,
                    size,
                    true,
                    true,
                    std::u64::max_value!(),
                    &clock,
                    test.ctx(),
                );
                i = i + 1;
            };

            // Clean up
            return_shared(vault);
            return_shared(db_pool);
            return_to_address(user, vault_cap);
            clock::destroy_for_testing(clock);
        };

        //---- 4: Alice withdraw ----//
        test.next_tx(alice);
        {
            // -- 4. Alice Ops -- //
            let mut clock = create_clock_at_sec(1800, test.ctx());
            let mut vault = test.take_shared<LotusDBVault<LP_TOKEN>>();
            let oracle_ag = test.take_shared<oracle_ag::OracleAggregator>();
            let mut lotus_config = test.take_shared<LotusConfig>();
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 7_000_000_000, 1, 9, 1799);
            let usdc_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, 1799);
            let deep_price_info_object = build_pyth_price_info_object(&mut test, b"DEEP0000000000000000000000000000", 100_000, 1, 6, 1799);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            
            // -- 4.1. -- //
            let mut top_up_ticket = vault.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, SPAM>(&mut vault, &mut top_up_ticket, &clock);
            let alice_incentive = vault.pooling_redeem_incentive<LP_TOKEN, SPAM>(top_up_ticket, test.ctx());

            // -- 4.2 -- //
            let (sui_balance, usdc_balance) = vault.pooling_withdraw<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &mut db_pool,
                &sui_price_info_object,
                &usdc_price_info_object,
                &deep_price_info_object,
                &oracle_ag,
                &clock,
                test.ctx(),
            );

            // Clean up
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
            transfer::public_share_object(deep_price_info_object);
            transfer::public_share_object(alice_incentive);
            transfer::public_share_object(sui_balance);
            transfer::public_share_object(usdc_balance);
            return_shared(vault);
            return_shared(lp_farm);
            return_shared(oracle_ag);
            return_shared(lotus_config);
            return_shared(db_pool);
            clock::destroy_for_testing(clock);

        };

        end(test);
    }
}
