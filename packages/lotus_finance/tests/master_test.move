#[test_only]
module lotus_finance::master_test {
    use std::debug;
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self,Scenario, begin, end};
    use lotus_finance::lotus_lp_farm::{Self, LotusLPFarm, LotusLPFarmCap};

    #[test_only]
    public struct MASTER_TEST has drop {}

    public struct FOO has drop {}
    public struct BAR has drop {}

    const DUMMY_ADDRESS: address = @0xDDDD;

    #[test_only]
    fun create_clock_at_sec(ts: u64, ctx: &mut TxContext): Clock {
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, ts * 1000);
        clock
    }

    #[test]
    fun test_farm_creation_and_setup() {
        let admin = @0xA;
        let mut test = begin(admin);
        let mut ctx = tx_context::dummy();
        
        // Create LotusFarm
        test.next_tx(admin);
        // let (treasury, meta) = coin::create_currency(
        //     MASTER_TEST {}, 6, b"Lotus LP Token", b"", b"", option::none(), &mut ctx
        // );

        let (mut lp_farm, lp_farm_admin_cap) = lotus_lp_farm::new<MASTER_TEST>(test.ctx());
        let lp_farm_id = object::id(&lp_farm);
        let lp_farm_admin_cap_id = object::id(&lp_farm_admin_cap);
        transfer::public_transfer(lp_farm_admin_cap, admin);
        transfer::public_share_object(lp_farm);


        // Setup LotusFarm
        test.next_tx(admin);
        {
            let clock = create_clock_at_sec(100, test.ctx());
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<MASTER_TEST>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_sender_by_id<LotusLPFarmCap>(lp_farm_admin_cap_id);
            // Add TD Farm
            lp_farm.add_td_farm_for_test<MASTER_TEST, FOO>(&lp_farm_admin_cap, 200, test.ctx());


            // Set unlock rate
            // lp_farm.set_farm_unlock_rate<MASTER_TEST, FOO>(100, &clock, test.ctx());

            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_sender(&test, lp_farm_admin_cap);
            clock::destroy_for_testing(clock);
        };
        end(test);
    }
}