module lotus_finance::lotus_config {
    use std::type_name::{Self, TypeName};
    use std::ascii::String;
    use std::string::{Self as STD_STRING};
    use std::debug;
    use sui::package;
    use sui::table::{Self, Table};
    use lotus_finance::consts::GET_CURRENT_VERSION;

    public struct LOTUS_CONFIG has drop {}

    // Protocol Status
    // 0: Normal
    // 1: Freeze

    public struct LotusConfig has key {
        id: UID,
        current_version: u64,
        protocol_status: u64,
        performance_fee_bps: u64,
        strategy_fee_bps: u64,
        cold_down_ms: u64,
        early_withdrawal_fee_bps: u64, // Early withdrawal fee in basis points, prevent arbitrage against the pool.
        max_deep_fee_bps: u64, // Maximum deep fee over vault total value in basis points, usually 0-10_000 (0-100%).
        min_pooling_deposit_value: u64, // Minimum pooling deposit USD value in the pool.
        max_deposit_token_ratio_diff_bps: u64, // Maximum deposit token ratio difference in basis points, usually 0-10_000 (0-100%).
        configs: Table<String, u64>,
    }

    public struct LotusConfigCap has key, store {
        id: UID,
        lotus_config: ID,
    }

    fun new(ctx: &mut TxContext): (LotusConfig, LotusConfigCap) {
        let lotus_config = LotusConfig {
            id: object::new(ctx),
            current_version: 0,         // Current version of the protocol on-chain part. Start from 0 which is lower than any future version.
            protocol_status: 0,
            performance_fee_bps: 0,     // Protocol performance fee in basis points, usually 0-1_000.
            strategy_fee_bps: 0,        // Strategy performance fee in basis points, usually 0-1_000. In addition to the protocol fee.
            early_withdrawal_fee_bps: 0, // Early withdrawal fee in basis points, prevent arbitrage against the pool.
            cold_down_ms: 0,
            max_deep_fee_bps: 100, // Default maximum deep size for the protocol.
            min_pooling_deposit_value: 1_000_000, // Default minimum pooling deposit value in USD, 6 decimal representation.
            max_deposit_token_ratio_diff_bps: 9_999, // Default maximum deposit token ratio difference in basis points, usually 0-10_000 (0-100%).
            configs: table::new(ctx),
        };
        let lotus_config_cap = LotusConfigCap {
            id: object::new(ctx),
            lotus_config: object::id(&lotus_config),
        };
        (lotus_config, lotus_config_cap)
    }

    fun init(otw: LOTUS_CONFIG, ctx: &mut TxContext) {
        let (lotus_config, lotus_config_cap) = new(ctx);
        transfer::share_object(lotus_config);
        transfer::transfer(lotus_config_cap, tx_context::sender(ctx));
        package::claim_and_keep(otw, ctx);
    }

    public fun assert_lotus_config_cap(
        self: &LotusConfig,
        cap: &LotusConfigCap,
    ) {
        assert!(object::id(self) == cap.lotus_config);
    }

    public fun update_current_version(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        version: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        self.current_version = version;
    }

    public fun update_protocol_status(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        status: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        self.protocol_status = status;
    }

    public fun update_performance_fee_bps(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        fee_bps: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(fee_bps + self.strategy_fee_bps < 5_000);
        self.performance_fee_bps = fee_bps;
    }

    public fun update_strategy_fee_bps(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        fee_bps: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(fee_bps + self.performance_fee_bps < 5_000);
        self.strategy_fee_bps = fee_bps;
    }

    public fun update_cold_down_ms(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        ms: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(ms < 1000 * 3600 * 24); // 1 day
        self.cold_down_ms = ms;
    }

    public fun update_early_withdrawal_fee_bps(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        bps: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(bps > 0);
        assert!(bps < 500); // 5%
        self.early_withdrawal_fee_bps = bps;
    }

    public fun update_max_deep_fee_bps(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        bps: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(bps > 0);
        assert!(bps < 100); // 1%
        self.max_deep_fee_bps = bps;
    }
    
    public fun update_min_pooling_deposit_value(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        value: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        self.min_pooling_deposit_value = value;
    }

    public fun update_max_deposit_token_ratio_diff_bps(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        bps: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        assert!(bps > 0);
        assert!(bps < 10_000); // 100%
        self.max_deposit_token_ratio_diff_bps = bps;
    }

    public fun update_config(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        key: String,
        value: u64,
    ) {
        assert_lotus_config_cap(self, cap);
        if (!self.configs.contains(key)) {
            self.configs.add(key, value);
        } else {
            let old_value = self.configs.borrow_mut(key);
            *old_value = value;
        }
    }

    public fun remove_config(
        self: &mut LotusConfig,
        cap: &LotusConfigCap,
        key: String,
    ) {
        assert_lotus_config_cap(self, cap);
        self.configs.remove(key);
    }

    public fun get_config(
        self: &LotusConfig,
        key: String,
    ): u64 {
        assert!(self.configs.contains(key));
        self.configs[key]
    }

    public fun get_protocol_status(
        self: &LotusConfig,
    ): u64 {
        self.protocol_status
    }

    public fun assert_protocol_status_ok(
        self: &LotusConfig,
    ) {
        assert!(self.protocol_status == 0);
    }

    public fun assert_current_version(
        self: &LotusConfig,
    ) {
        assert!(self.current_version == GET_CURRENT_VERSION());
    }

    public fun get_performance_fee_bps( self: &LotusConfig ): u64 { self.performance_fee_bps }

    public fun get_strategy_fee_bps( self: &LotusConfig ): u64 { self.strategy_fee_bps }

    public fun get_cold_down_ms( self: &LotusConfig ): u64 { self.cold_down_ms }

    public fun get_early_withdrawal_fee_bps( self: &LotusConfig ): u64 { self.early_withdrawal_fee_bps }

    public fun get_current_version( self: &LotusConfig ): u64 { self.current_version }

    public fun get_max_deep_fee_bps( self: &LotusConfig ): u64 { self.max_deep_fee_bps }

    public fun get_min_pooling_deposit_value( self: &LotusConfig ): u64 { self.min_pooling_deposit_value }

    public fun get_max_deposit_token_ratio_diff_bps( self: &LotusConfig ): u64 { self.max_deposit_token_ratio_diff_bps }

    #[test_only]
    public fun init_test(ctx: &mut TxContext) {
        init(LOTUS_CONFIG {}, ctx);
    }
}