#[test_only]
module lotus_finance::lotus_lp_farm_tests {
    use std::debug;
    use sui::object::id_from_address;
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use std::string::{Self as STD_STRING};
    use sui::coin::{Self, Coin, TreasuryCap, mint_for_testing};
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self,Scenario, begin, end, return_shared};
    use usdc::usdc::USDC;
    use token::deep::DEEP;
    use deepbook::constants::{Self};
    use deepbook::pool::{Self as db_pool, Pool as DBPool};
    use token_distribution::pool::assert_stake_shares_amount;
    use lotus_finance::oracle_ag;
    use lotus_finance::lotus_lp_farm::{Self, LotusLPFarm, LotusLPFarmCap};
    use lotus_finance::lotus_db_vault::{Self};
    use lotus_finance::lp_token::{Self, LP_TOKEN};
    use lotus_finance::lotus_config::{Self, LotusConfig, LotusConfigCap};
    use lotus_finance::lotus_vault_db_related_tests::{setup_test, create_acct_and_share_with_funds, setup_pool_with_default_fees_and_reference_pool};
    use lotus_finance::test_utils::{Self, create_clock_at_sec, set_clock_sec, MY_DEEP, MY_SUI, build_pyth_price_info_object, build_demo_usdc_price_info_object, build_demo_sui_price_info_object, setup_lotus_lp_farm, assert_proximity};

    public struct FOO has drop {}
    public struct BAR has drop {}

    const DUMMY_ADDRESS: address = @0xDDDD;

    #[test]
    fun test_farm_creation_and_setup() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);

        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            // Add TD Farm
            lp_farm.add_td_farm_for_test<LP_TOKEN, FOO>(&lp_farm_admin_cap, 200, test.ctx());

            assert!(lp_farm.td_farm_length<LP_TOKEN>() == 1);
            assert!(lp_farm.td_farm_contains<LP_TOKEN, FOO>());
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }

    #[test]
    fun test_farm_create_incentivized_vault() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_demo_sui_price_info_object(&mut test, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_demo_usdc_price_info_object(&mut test, clock.timestamp_ms() / 1000);

            // Add TD Farm
            lp_farm.add_td_farm<LP_TOKEN, FOO>(&lp_farm_admin_cap, 200, test.ctx());
            lp_farm.add_td_farm<LP_TOKEN, BAR>(&lp_farm_admin_cap, 200, test.ctx());
            assert!(lp_farm.td_farm_length<LP_TOKEN>() == 2);
            assert!(lp_farm.td_farm_contains<LP_TOKEN, FOO>());
            assert!(lp_farm.td_farm_contains<LP_TOKEN, BAR>());
            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault, vault_creator_cap, vault_trade_cap, mut ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000_000, test.ctx()),
                mint_for_testing<USDC>(2_000_000_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, FOO>(
                &mut vault, 
                &mut ticket, 
                &clock, 
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, BAR>(
                &mut vault, 
                &mut ticket, 
                &clock, 
            );
            lp_farm.destroy_create_pool_ticket(ticket);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, FOO>(&lp_farm_admin_cap, 105, &clock, test.ctx());
            assert!(lp_farm.vault_ids().contains(&object::id(&vault)));
            assert!(lp_farm.vault_td_farm_member_ids()[&object::id(&vault)] == vault.get_td_farm_member_key_id());
            assert!(lp_farm.td_farm_unlock_rate<LP_TOKEN, FOO>() == 105);

            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(db_pool);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }


    #[test, expected_failure(abort_code = lotus_finance::lotus_lp_farm::EInvalidDBPool)]
    fun test_farm_create_incentivized_vault_unauthorized_db_pool() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let spam_db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            // lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &spam_db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let lotus_config = test.take_shared<LotusConfig>();
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000_000, 1, 6, clock.timestamp_ms() / 1000);

            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault, vault_creator_cap, vault_trade_cap, mut ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &spam_db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );

            lp_farm.destroy_create_pool_ticket(ticket);

            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_shared(spam_db_pool);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, ag_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }


    #[test, expected_failure(abort_code = lotus_finance::lotus_lp_farm::EMaxTVLExceeds)]
    fun test_farm_create_incentivized_vault_exceeds_max_tvl() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());

        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000_000, 1, 6, clock.timestamp_ms() / 1000);

            // Case
            // USDC price: 1
            // Vault deposit: 1.2 USDC, 1_200_000
            // Set remain quota to 1_999_000
            // Second deposit should fail.

            lp_farm.update_max_tvl<LP_TOKEN>(&lp_farm_admin_cap, 1_999_000);

            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault, vault_creator_cap, vault_trade_cap, mut ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_200_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );

            debug::print(&STD_STRING::utf8(b"Successfully created the first Vault"));

            lp_farm.update_max_tvl<LP_TOKEN>(&lp_farm_admin_cap, 999_000);

            lp_farm.destroy_create_pool_ticket(ticket);

            let (mut vault2, vault_creator_cap2, vault_trade_cap2, mut ticket2) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_200_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );

            lp_farm.destroy_create_pool_ticket(ticket2);

            transfer::public_share_object(vault);
            transfer::public_share_object(vault_trade_cap);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault2);
            transfer::public_share_object(vault_creator_cap2);
            transfer::public_share_object(vault_trade_cap2);
            test_scenario::return_shared(db_pool);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }


    #[test, expected_failure(abort_code = lotus_finance::lotus_lp_farm::EinvalidTicketLength)]
    fun test_farm_create_incentivized_vault_incomplete() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool);
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000_000, 1, 6, clock.timestamp_ms() / 1000);


            // Add TD Farm
            lp_farm.add_td_farm<LP_TOKEN, FOO>(&lp_farm_admin_cap, 200, test.ctx());
            lp_farm.add_td_farm<LP_TOKEN, BAR>(&lp_farm_admin_cap, 200, test.ctx());
            assert!(lp_farm.td_farm_length<LP_TOKEN>() == 2);
            assert!(lp_farm.td_farm_contains<LP_TOKEN, FOO>());
            assert!(lp_farm.td_farm_contains<LP_TOKEN, BAR>());
            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault, vault_creator_cap, vault_trade_cap, mut ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, FOO>(
                &mut vault, 
                &mut ticket, 
                &clock, 
            );
            //// Missing BAR will cause panic
            // lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, BAR>(
            //     &mut vault, 
            //     &mut ticket, 
            //     &clock, 
            // );
            lp_farm.destroy_create_pool_ticket(ticket);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, FOO>(&lp_farm_admin_cap, 100, &clock, test.ctx());

            // Get unlock rate
            let unlock_rate = lp_farm.td_farm_unlock_rate<LP_TOKEN, FOO>();
            assert!(unlock_rate == 100);

            // Clean up
            transfer::public_share_object(vault);
            transfer::public_share_object(vault_creator_cap);
            transfer::public_share_object(vault_trade_cap);
            test_scenario::return_shared(db_pool);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }

    #[test]
    fun test_uneven_vault_weights() {
        // Setup test scenario.
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id_1 = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        test.next_tx(admin);
        {
            // Initialize clock and obtain LP Farm objects.
            let mut clock = create_clock_at_sec(100, test.ctx());
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            let mut db_pool_1 = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id_1);
            // Allow USDC as deposit asset.
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool_1);

            // Add TD Farm for incentive distribution (using USDC as incentive type).
            lp_farm.add_td_farm_for_test<LP_TOKEN, USDC>(&lp_farm_admin_cap, 200, test.ctx());

            // Prepare Oracle for vault creation.
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000_000, 1, 6, clock.timestamp_ms() / 1000);

            // Create two incentivized vaults with different deposit amounts.
            // Vault with minimal deposit (small weight)
            let (mut vault_small, vault_small_creator_cap, vault_small_trade_cap, mut ticket_small) =
                lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    &db_pool_1,
                    mint_for_testing<SUI>(500_000, test.ctx()),
                    mint_for_testing<USDC>(500_000_000, test.ctx()),
                    &ag,
                    &base_price_info_object,
                    &quote_price_info_object,
                    &clock, 
                    test.ctx()
                );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, USDC>(
                &mut vault_small, 
                &mut ticket_small, 
                &clock
            );
            lp_farm.destroy_create_pool_ticket(ticket_small);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, USDC>(&lp_farm_admin_cap, 10_000_000, &clock, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, USDC>(coin::mint_for_testing<USDC>(10_000_000_000, test.ctx()), &clock);

            // Vault with large deposit (large weight)
            let (mut vault_large, vault_large_creator_cap, vault_large_trade_cap, mut ticket_large) =
                lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    &db_pool_1,
                    mint_for_testing<SUI>(50_000_000, test.ctx()),
                    mint_for_testing<USDC>(50_000_000_000_000, test.ctx()),
                    &ag,
                    &base_price_info_object,
                    &quote_price_info_object,
                    &clock, 
                    test.ctx()
                );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, USDC>(
                &mut vault_large, 
                &mut ticket_large, 
                &clock
            );
            lp_farm.destroy_create_pool_ticket(ticket_large);

            // Advance clock to allow unlocking of incentives.
            set_clock_sec(&mut clock, 400);

            // Retrieve accrued incentive values.
            let mut top_up_ticket_small = vault_small.new_top_up_ticket();
            let mut top_up_ticket_large = vault_large.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, USDC>(&mut vault_small, &mut top_up_ticket_small, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, USDC>(&mut vault_large, &mut top_up_ticket_large, &clock);

            let incentive_small = vault_small.pooling_redeem_incentive<LP_TOKEN, USDC>(top_up_ticket_small, test.ctx());
            let incentive_large = vault_large.pooling_redeem_incentive<LP_TOKEN, USDC>(top_up_ticket_large, test.ctx());
            // 200s should distribute total of 10_000_000 * 200 = 2_000_000_000.
            // Small vault should receive 500 / 50_000_500 * 2_000_000_000 = 20000.
            // Large vault should receive 50_000_000 / 50_005_000 * 2_000_000_000 = 1_999_980_000.
            debug::print(&incentive_small.value());
            debug::print(&incentive_large.value());
            assert_proximity(incentive_small.value(), 20000, 50);
            assert_proximity(incentive_large.value(), 1_999_980_000, 50);

            // Return objects to the test framework.
            test_scenario::return_shared(db_pool_1);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            transfer::public_share_object(vault_small);
            transfer::public_share_object(vault_small_creator_cap);
            transfer::public_share_object(vault_small_trade_cap);
            transfer::public_share_object(vault_large);
            transfer::public_share_object(vault_large_creator_cap);
            transfer::public_share_object(vault_large_trade_cap);
            transfer::public_share_object(incentive_small);
            transfer::public_share_object(incentive_large);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }


    #[test]
    fun test_uneven_vault_weights_2() {
        // Setup test scenario.
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        test.next_tx(admin);
        {
            // Initialize clock and obtain LP Farm objects.
            let mut clock = create_clock_at_sec(100, test.ctx());
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            // Allow USDC as deposit asset.
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool);
            // Add TD Farm for incentive distribution (using USDC as incentive type).
            lp_farm.add_td_farm_for_test<LP_TOKEN, USDC>(&lp_farm_admin_cap, 200, test.ctx());

            // Prepare Oracle for vault creation.
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_demo_sui_price_info_object(&mut test, clock.timestamp_ms() / 1000);
            let quote_price_info_object = test_utils::build_demo_usdc_price_info_object(&mut test, clock.timestamp_ms() / 1000);

            // Create two incentivized vaults with different deposit amounts.
            // Vault with minimal deposit (small weight)
            let (mut vault_small, vault_small_creator_cap, vault_small_trade_cap, mut ticket_small) =
                lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    &db_pool,
                    mint_for_testing<SUI>(500_000_000, test.ctx()),
                    mint_for_testing<USDC>(2_000_000_000, test.ctx()),
                    &ag,
                    &base_price_info_object,
                    &quote_price_info_object,
                    &clock, 
                    test.ctx()
                );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, USDC>(
                &mut vault_small, 
                &mut ticket_small, 
                &clock
            );
            lp_farm.destroy_create_pool_ticket(ticket_small);
            lp_farm.set_farm_unlock_rate<LP_TOKEN, USDC>(&lp_farm_admin_cap, 10_000_000, &clock, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, USDC>(coin::mint_for_testing<USDC>(10_000_000_000, test.ctx()), &clock);

            // Vault with large deposit (large weight)
            let (mut vault_large, vault_large_creator_cap, vault_large_trade_cap, mut ticket_large) =
                lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                    &lotus_config,
                    &db_pool,
                    mint_for_testing<SUI>(50_000_000, test.ctx()),
                    mint_for_testing<USDC>(500_000_000_000_000, test.ctx()),
                    &ag,
                    &base_price_info_object,
                    &quote_price_info_object,
                    &clock, 
                    test.ctx()
                );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, USDC>(
                &mut vault_large, 
                &mut ticket_large, 
                &clock
            );
            lp_farm.destroy_create_pool_ticket(ticket_large);

            // Advance clock to allow unlocking of incentives.
            set_clock_sec(&mut clock, 400);

            // Retrieve accrued incentive values.
            let mut top_up_ticket_small = vault_small.new_top_up_ticket();
            let mut top_up_ticket_large = vault_large.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, USDC>(&mut vault_small, &mut top_up_ticket_small, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, USDC>(&mut vault_large, &mut top_up_ticket_large, &clock);
            
            let incentive_small = vault_small.pooling_redeem_incentive<LP_TOKEN, USDC>(top_up_ticket_small, test.ctx());
            let incentive_large = vault_large.pooling_redeem_incentive<LP_TOKEN, USDC>(top_up_ticket_large, test.ctx());

            // 200s should distribute total of 10_000_000 * 200 = 2_000_000_000.
            // Small vault should receive 500 / 50_000_500 * 2_000_000_000 = 20000.
            // Large vault should receive 500_000_000 / 50_005_000 * 2_000_000_000 = 1_999_980_000.
            debug::print(&incentive_small.value());
            debug::print(&incentive_large.value());
            assert_proximity(incentive_small.value(), 8000, 5);
            assert_proximity(incentive_large.value(), 1_999_991_999, 50);

            // Return objects to the test framework.
            test_scenario::return_shared(lp_farm);
            test_scenario::return_shared(db_pool);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            transfer::public_share_object(vault_small);
            transfer::public_share_object(vault_small_creator_cap);
            transfer::public_share_object(vault_small_trade_cap);
            transfer::public_share_object(vault_large);
            transfer::public_share_object(vault_large_creator_cap);
            transfer::public_share_object(vault_large_trade_cap);
            transfer::public_share_object(incentive_small);
            transfer::public_share_object(incentive_large);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }

    #[test]
    fun test_farm_distribution() {
        let admin = @0xA;
        let mut test = begin(admin);
        let (lp_farm_id, lp_farm_admin_cap_id) = setup_lotus_lp_farm<LP_TOKEN>(&mut test, admin);
        oracle_ag::init_test(test.ctx());
        lotus_config::init_test(test.ctx());
        let registry_id = setup_test(admin, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(
            admin,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            DEEP,
        >(admin, registry_id, balance_manager_id_alice, &mut test);

        // Setup LotusFarm
        test.next_tx(admin);
        {
            let mut db_pool = test.take_shared_by_id<DBPool<SUI, USDC>>(pool_id);
            let mut clock = create_clock_at_sec(100, test.ctx());
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LP_TOKEN>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, SUI>(&lp_farm_admin_cap);
            lp_farm.add_allowed_deposit_asset<LP_TOKEN, USDC>(&lp_farm_admin_cap);
            lp_farm.add_allowed_db_pool<LP_TOKEN, SUI, USDC>(&lp_farm_admin_cap, &db_pool);

            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(test.sender());
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(test.sender());
            lotus_config.update_current_version(&lotus_config_cap, 1);
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<USDC>(&ag_cap, 6);
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_pyth_price_id<SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_coin_decimal<SUI>(&ag_cap, 9);
            ag.update_coin_config<SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            let base_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000, 1, 6, clock.timestamp_ms() / 1000);

            // Add TD Farm
            lp_farm.add_td_farm<LP_TOKEN, FOO>(&lp_farm_admin_cap, 200, test.ctx());
            lp_farm.add_td_farm<LP_TOKEN, BAR>(&lp_farm_admin_cap, 200, test.ctx());
            assert!(lp_farm.td_farm_length<LP_TOKEN>() == 2);
            assert!(lp_farm.td_farm_contains<LP_TOKEN, FOO>());
            assert!(lp_farm.td_farm_contains<LP_TOKEN, BAR>());

            //// Test case:
            // 1. FOO: +inf supply, 10 unlock rate; BAR: +inf supply, 20 unlock rate
            // 2. Vault1: 100 weight; Vault2: 300 weight
            // 3. Unlock start from t=200s
            
            // -- Vault 1 --
            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault1, vault_creator_cap1, vault_trade_cap1, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, FOO>(&mut vault1, &mut create_vault_ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, BAR>(&mut vault1, &mut create_vault_ticket, &clock);

            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // -- Vault 2 --
            // Create IncentivizedDBVault, add to td_farms using hot potato ticket
            let (mut vault2, vault_creator_cap2, vault_trade_cap2, mut create_vault_ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(3_000_000, test.ctx()),
                mint_for_testing<USDC>(3_000_000_000, test.ctx()),
                &ag,
                &base_price_info_object,
                &quote_price_info_object,
                &clock, 
                test.ctx()
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, FOO>(&mut vault2, &mut create_vault_ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, BAR>(&mut vault2, &mut create_vault_ticket, &clock);

            lp_farm.destroy_create_pool_ticket(create_vault_ticket);

            // -- Topup td_farm --
            let coin: Coin<FOO> = coin::mint_for_testing<FOO>(1000000, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, FOO>(coin, &clock);
            let coin: Coin<BAR> = coin::mint_for_testing<BAR>(1000000, test.ctx());
            lp_farm.top_up_incentive_balance<LP_TOKEN, BAR>(coin, &clock);

            lp_farm.set_farm_unlock_rate<LP_TOKEN, FOO>(&lp_farm_admin_cap, 10, &clock, test.ctx());
            lp_farm.set_farm_unlock_rate<LP_TOKEN, BAR>(&lp_farm_admin_cap, 20, &clock, test.ctx());

            // Distribute
            // T = 250s, unlock rate = 10, 20
            // Vault1 incentive FOO = 10 * (250 - 200) * (100 / 400) = 125
            set_clock_sec(&mut clock, 250);
            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            let vault1_foo = vault1.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket1, test.ctx());
            let vault2_foo = vault2.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket2, test.ctx());
            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            let vault1_bar = vault1.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket1, test.ctx());
            let vault2_bar = vault2.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket2, test.ctx());
            assert_proximity(vault1_foo.value(), 125, 3);
            assert_proximity(vault2_foo.value(), 375, 3);
            assert_proximity(vault1_bar.value(), 250, 3);
            assert_proximity(vault2_bar.value(), 750, 3);

            // T = 300s
            // Vault1 incentive FOO = 10 * (300 - 200) * (100 / 400) = 250
            set_clock_sec(&mut clock, 300);
            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            let vault1_foo_2 = vault1.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket1, test.ctx());
            let vault2_foo_2 = vault2.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket2, test.ctx());
            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            let vault1_bar_2 = vault1.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket1, test.ctx());
            let vault2_bar_2 = vault2.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket2, test.ctx());
            
            debug::print(&vault1_foo_2.value());
            assert_proximity(vault1_foo_2.value() + vault1_foo.value(), 250, 3);
            assert_proximity(vault2_foo_2.value() + vault2_foo.value(), 750, 3);
            assert_proximity(vault1_bar_2.value() + vault1_bar.value(), 500, 3);
            assert_proximity(vault2_bar_2.value() + vault2_bar.value(), 1500, 3);

            // T = 350s
            // Add Vault3: 100 weight
            set_clock_sec(&mut clock, 350);
            let base_price_info_object_2 = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", 1_000_000_000, 1, 9, clock.timestamp_ms() / 1000);
            let quote_price_info_object_2 = build_pyth_price_info_object(&mut test, b"USDC0000000000000000000000000000", 1_000_000_000, 1, 6, clock.timestamp_ms() / 1000);
            let (mut vault3, vault_creator_cap3, vault_trade_cap3, mut ticket) = lp_farm.create_incentivized_db_vault<LP_TOKEN, SUI, USDC>(
                &lotus_config,
                &db_pool,
                mint_for_testing<SUI>(1_000_000, test.ctx()),
                mint_for_testing<USDC>(1_000_000, test.ctx()),
                &ag,
                &base_price_info_object_2,
                &quote_price_info_object_2,
                &clock, 
                test.ctx()
            );
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, FOO>(&mut vault3, &mut ticket, &clock);
            lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LP_TOKEN, BAR>(&mut vault3, &mut ticket, &clock);
            lp_farm.destroy_create_pool_ticket(ticket);

            // T = 400s
            // Vault1 incentive FOO = 10 * (350 - 200) * (100 / 400) + 10 * (400 - 350) * (100 / 500) = 375 + 100 = 475
            // Vault3 incentive FOO = 10 * (400 - 350) * (100 / 500) = 100
            set_clock_sec(&mut clock, 400);
            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            let mut top_up_ticket3 = vault3.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault3, &mut top_up_ticket3, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault3, &mut top_up_ticket3, &clock);
            let vault1_foo_3 = vault1.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket1, test.ctx());
            let vault2_foo_3 = vault2.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket2, test.ctx());
            let vault3_foo_3 = vault3.pooling_redeem_incentive<LP_TOKEN, FOO>(top_up_ticket3, test.ctx());

            let mut top_up_ticket1 = vault1.new_top_up_ticket();
            let mut top_up_ticket2 = vault2.new_top_up_ticket();
            let mut top_up_ticket3 = vault3.new_top_up_ticket();
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault1, &mut top_up_ticket1, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault2, &mut top_up_ticket2, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, FOO>(&mut vault3, &mut top_up_ticket3, &clock);
            lp_farm.top_up_to_td_pool<LP_TOKEN, BAR>(&mut vault3, &mut top_up_ticket3, &clock);
            let vault1_bar_3 = vault1.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket1, test.ctx());
            let vault2_bar_3 = vault2.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket2, test.ctx());
            let vault3_bar_3 = vault3.pooling_redeem_incentive<LP_TOKEN, BAR>(top_up_ticket3, test.ctx());
            
            // // Vault1 ~= 475, Vault3 ~= 100
            debug::print(&vault1_foo_3.value());
            assert_proximity(vault1_foo_3.value() + vault1_foo_2.value() + vault1_foo.value() , 475, 4);
            assert_proximity(vault3_foo_3.value() , 100, 4);

            //// Clean up
            transfer::public_share_object(vault1);
            transfer::public_share_object(vault2);
            transfer::public_share_object(vault3);
            transfer::public_share_object(vault_creator_cap1);
            transfer::public_share_object(vault_creator_cap2);
            transfer::public_share_object(vault_creator_cap3);
            transfer::public_share_object(vault_trade_cap1);
            transfer::public_share_object(vault_trade_cap2);
            transfer::public_share_object(vault_trade_cap3);
            test_scenario::return_shared(db_pool);
            test_scenario::return_shared(lp_farm);
            test_scenario::return_shared(ag);
            test_scenario::return_to_sender(&test, ag_cap);
            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_sender(&test, lotus_config_cap);
            transfer::public_share_object(base_price_info_object);
            transfer::public_share_object(quote_price_info_object);
            transfer::public_share_object(base_price_info_object_2);
            transfer::public_share_object(quote_price_info_object_2);

            transfer::public_share_object(vault1_foo);
            transfer::public_share_object(vault2_foo);
            transfer::public_share_object(vault1_bar);
            transfer::public_share_object(vault2_bar);
            transfer::public_share_object(vault1_foo_2);
            transfer::public_share_object(vault2_foo_2);
            transfer::public_share_object(vault1_bar_2);
            transfer::public_share_object(vault2_bar_2);
            transfer::public_share_object(vault1_foo_3);
            transfer::public_share_object(vault2_foo_3);
            transfer::public_share_object(vault1_bar_3);
            transfer::public_share_object(vault2_bar_3);
            transfer::public_share_object(vault3_foo_3);
            transfer::public_share_object(vault3_bar_3);

            // teller.destroy();
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }
}