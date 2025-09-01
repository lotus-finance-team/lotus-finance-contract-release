module lotus_finance::oracle_ag_tests {
    use sui::test_scenario::{Self,Scenario, begin, end, return_shared, return_to_address};
    use sui::clock::{Self, Clock};
    use std::type_name;
    use std::debug;
    use std::string::{Self as STD_STRING};
    use pyth::price_identifier;
    use pyth::price_feed;
    use pyth::price_info;
    use pyth::price;
    use pyth::i64;
    use pyth::pyth;
    use usdc::usdc::USDC;
    use lotus_finance::oracle_ag;
    use lotus_finance::test_utils::{Self, create_clock_at_sec, build_pyth_price_info_object, MY_SUI, MY_DEEP};

    const ADMIN: address = @0xAD;
    const USER: address = @0xA;


    #[test]
    fun test_oracle_aggregator() {
        let mut test = begin(ADMIN);

        oracle_ag::init_test(test.ctx());
        let sender = test.sender();
        test.next_tx(sender);
        {
            let clock = create_clock_at_sec(1001, test.ctx());
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(sender);

            // Insert test pyth price for SUI and DEEP
            ag.update_pyth_price_id<MY_SUI>(&ag_cap, b"SUI_PYTH_ADDRESS");
            ag.update_pyth_price_id<MY_DEEP>(&ag_cap, b"DEEP_PYTH_ADDRESS");
            ag.update_coin_decimal<MY_SUI>(&ag_cap, 9);
            ag.update_coin_decimal<MY_DEEP>(&ag_cap, 6);
            ag.update_coin_config<MY_SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<MY_DEEP>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            
            assert!(ag.get_pyth_address<MY_SUI>() == b"SUI_PYTH_ADDRESS", 0);
            assert!(ag.get_pyth_address<MY_DEEP>() == b"DEEP_PYTH_ADDRESS", 0);
            assert!(ag.get_coin_decimal<MY_SUI>() == 9);
            assert!(ag.get_coin_decimal<MY_DEEP>() == 6);

            // Mock price
            let sui_price_value: u64 = 100;
            let sui_price_info_object = build_pyth_price_info_object(&mut test, b"SUI00000000000000000000000000000", sui_price_value, 1, 9, 1000);
            let price_info = price_info::get_price_info_from_price_info_object(&sui_price_info_object);
            let price_struct = pyth::get_price_no_older_than(&sui_price_info_object, &clock, 1000);
            let price_i64 = price::get_price(&price_struct);
            let price_u64 = price_i64.get_magnitude_if_positive();
            assert!(price_u64 == sui_price_value, 0);
            transfer::public_share_object(sui_price_info_object);

            return_shared(ag);
            clock::destroy_for_testing(clock);
            return_to_address(sender, ag_cap);
        };

        end(test);
    }

    #[test]
    fun test_calc_usd_value() {
        let mut test = begin(ADMIN);

        oracle_ag::init_test(test.ctx());
        let sender = test.sender();
        test.next_tx(sender);
        {
            let clock = create_clock_at_sec(1001, test.ctx());
            let mut ag = test.take_shared<oracle_ag::OracleAggregator>();
            let ag_cap = test.take_from_address<oracle_ag::OracleAggregatorCap>(sender);

            // Insert test pyth price for SUI and DEEP
            ag.update_pyth_price_id<MY_SUI>(&ag_cap, b"SUI00000000000000000000000000000");
            ag.update_pyth_price_id<MY_DEEP>(&ag_cap, b"DEEP0000000000000000000000000000");
            ag.update_pyth_price_id<USDC>(&ag_cap, b"USDC0000000000000000000000000000");
            ag.update_coin_decimal<MY_SUI>(&ag_cap, 9);
            ag.update_coin_decimal<MY_DEEP>(&ag_cap, 6);
            ag.update_coin_config<MY_SUI>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<MY_DEEP>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            ag.update_coin_config<USDC>(&ag_cap, oracle_ag::GET_CPYTH_PRICE());
            
            let sui_price_info_object = test_utils::build_demo_sui_price_info_object(&mut test, 1000);
            let usdc_price_info_object = test_utils::build_demo_usdc_price_info_object(&mut test, 1000);

            // Case 1
            // SUI: 103
            // Pyth: SUI price: 338556589, exp: 8. 
            // Amount: SUI 23_000_000_000
            // USD value: (23_000_000_000 * 1e-9) * (338556589 * 1e-8) * 1e6 = 77_868_015
            let amount = 23_000_000_000;
            let usd_value = ag.calc_usd_value<MY_SUI>(&sui_price_info_object, amount, &clock);
            debug::print(&STD_STRING::utf8(b"Test USD value: usd_value"));
            debug::print(&usd_value);
            assert!(usd_value == 77_868_015, 0);

            // Clean up
            return_shared(ag);
            clock::destroy_for_testing(clock);
            return_to_address(sender, ag_cap);
            transfer::public_share_object(sui_price_info_object);
            transfer::public_share_object(usdc_price_info_object);
        };

        end(test);
    }
}