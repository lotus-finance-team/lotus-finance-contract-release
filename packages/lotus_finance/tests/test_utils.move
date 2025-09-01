module lotus_finance::test_utils {
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self,Scenario, begin, end, return_shared, return_to_address};
    use pyth::price_identifier;
    use pyth::price_feed;
    use pyth::price_info;
    use pyth::price;
    use pyth::i64;
    use pyth::pyth;
    use lotus_finance::lotus_lp_farm::{Self, LotusLPFarm, LotusLPFarmCap};
    use lotus_finance::lotus_db_vault::{Self};

    public struct MY_DEEP has store {}
    public struct MY_SUI has store {}
    public struct MY_USDC has store {}

    #[test_only]
    public fun assert_proximity(a: u64, b: u64, epsilon: u64) {
        assert!(a > b - epsilon);
        assert!(a < b + epsilon);
    }

    #[test_only]
    public fun create_clock_at_sec(ts: u64, ctx: &mut TxContext): Clock {
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, ts * 1000);
        clock
    }

    #[test_only]
    public fun set_clock_sec(clock: &mut Clock, ts: u64) {
        clock::set_for_testing(clock, ts * 1000);
    }

    // Example:
    //      USDC / USD: price_value: 99995001, conf_value: 98352, exp_value: 8, timestamp: 1630000000
    #[test_only]
    public fun build_pyth_price_info_object(
        test: &mut Scenario,
        id: vector<u8>,
        price_value: u64,
        conf_value: u64,
        exp_value: u64,
        timestamp: u64,
    ): price_info::PriceInfoObject{
        // 1. price identifier 2. price info 3. price info object
        let price_id = price_identifier::from_byte_vec(id);
        // SUI price: 100, confidence: 1, expo: 9
        let price = price::new(i64::new(price_value, false), conf_value, i64::new(exp_value, true), timestamp);
        let price_feed = price_feed::new(price_id, price, price);
        let price_info = price_info::new_price_info(timestamp - 2, timestamp - 1, price_feed);
        let price_info_object = price_info::new_price_info_object_for_test(price_info, test.ctx());
        price_info_object
    }

    #[test_only]
    public fun build_demo_sui_price_info_object(test: &mut Scenario, timestamp: u64): price_info::PriceInfoObject {
        build_pyth_price_info_object(test, b"SUI00000000000000000000000000000", 338556589, 236078, 8, timestamp)
    }
    #[test_only]
    public fun build_demo_usdc_price_info_object(test: &mut Scenario, timestamp: u64): price_info::PriceInfoObject {
        build_pyth_price_info_object(test, b"USDC0000000000000000000000000000", 99995001, 98352, 8, timestamp)
    }

    #[test_only]
    public fun setup_lotus_lp_farm<T>(test: &mut Scenario, admin: address): (ID, ID) {
        let mut ctx = tx_context::dummy();
        // Create LotusFarm
        test.next_tx(admin);
        let (mut lp_farm, lp_farm_admin_cap) = lotus_lp_farm::new<T>(test.ctx());
        let lp_farm_id = object::id(&lp_farm);
        let lp_farm_admin_cap_id = object::id(&lp_farm_admin_cap);
        transfer::public_transfer(lp_farm_admin_cap, admin);
        transfer::public_share_object(lp_farm);

        (lp_farm_id, lp_farm_admin_cap_id)
    }
}