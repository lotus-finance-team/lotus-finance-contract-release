module lotus_finance::lotus_db_vault_tests {
    use std::debug;
    use sui::sui::SUI;
    use sui::address::{Self};
    use sui::coin::{Self, Coin, mint_for_testing};
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self,Scenario, begin, end};
    use lotus_finance::lotus_db_vault::{Self, LotusDBVault, LotusDBVaultCap};
    use lotus_finance::lotus_lp_farm::{Self, LotusLPFarm, LotusLPFarmCap};
    use lotus_finance::lotus_config::{Self, LotusConfig, LotusConfigCap};

    #[test_only]
    public struct LOTUS_DB_VAULT_TESTS has drop {}

    public struct FOO has drop {}
    public struct BAR has drop {}

    const DUMMY_ADDRESS: address = @0xDDDD;
    const Admin: address = @0xA;
    const User1: address = @0x11;
    const User2: address = @0x22;

    #[test_only]
    fun create_clock_at_sec(ts: u64, ctx: &mut TxContext): Clock {
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, ts * 1000);
        clock
    }

    #[test]
    fun test_create_vault_and_deposit() {
        let mut test = begin(User1);
        let dummy_id = object::id_from_address(DUMMY_ADDRESS);
        let vault = lotus_db_vault::new<LOTUS_DB_VAULT_TESTS>(dummy_id, test.ctx());
        let vault_id = object::id(&vault);
        transfer::public_share_object(vault);
        test.next_tx(User1);
        {
            let mut vault = test.take_shared_by_id<LotusDBVault<LOTUS_DB_VAULT_TESTS>>(vault_id);
            // Test mint lotus cap
            // let trade_cap = vault.mint_lotus_trade_cap<LOTUS_DB_VAULT_TESTS>(&vault_cap, test.ctx());
            // Test deposit
            let deposit_coin = mint_for_testing<SUI>(1_000_000, test.ctx());
            vault.deposit<SUI, LOTUS_DB_VAULT_TESTS>(deposit_coin, test.ctx());

            test_scenario::return_shared(vault);
        };
        end(test);
    }

    #[test]
    fun test_create_vault_with_farm() {
        let admin = @0xA;
        let farm_admin = @0xF;
        let mut test = begin(admin);
        let mut ctx = tx_context::dummy();
        
        // Create LotusFarm
        test.next_tx(admin);
        let (mut lp_farm, lp_farm_admin_cap) = lotus_lp_farm::new<LOTUS_DB_VAULT_TESTS>(test.ctx());
        let lp_farm_id = object::id(&lp_farm);
        let lp_farm_admin_cap_id = object::id(&lp_farm_admin_cap);
        transfer::public_transfer(lp_farm_admin_cap, admin);
        transfer::public_share_object(lp_farm);

        lotus_config::init_test(test.ctx());
        test.next_tx(farm_admin);
        {
            let mut lotus_config = test.take_shared<LotusConfig>();
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(admin);
            lotus_config.update_current_version(&lotus_config_cap, 1);
            lotus_config.update_performance_fee_bps(&lotus_config_cap, 1500);
            lotus_config.update_cold_down_ms(&lotus_config_cap, 10 * 1000);

            test_scenario::return_shared(lotus_config);
            test_scenario::return_to_address(admin, lotus_config_cap);
        };

        test.next_tx(admin);
        {
            let mut lp_farm = test.take_shared_by_id<LotusLPFarm<LOTUS_DB_VAULT_TESTS>>(lp_farm_id);
            let lp_farm_admin_cap = test.take_from_address_by_id<LotusLPFarmCap>(admin, lp_farm_admin_cap_id);
            let mut vault = lotus_db_vault::new<LOTUS_DB_VAULT_TESTS>(lp_farm_id, test.ctx());
            let lotus_config_cap = test.take_from_address<LotusConfigCap>(admin);

            let lotus_vault_cap = vault.mint_lotus_vault_cap_with_config_cap(&lotus_config_cap, test.ctx());

            test_scenario::return_shared(lp_farm);
            test_scenario::return_to_address(admin, lp_farm_admin_cap);
            test_scenario::return_to_address(admin, lotus_config_cap);
            transfer::public_share_object(lotus_vault_cap);
            transfer::public_share_object(vault);
        };

        end(test);
    }
}