module lotus_finance::consts {
    use sui::sui::SUI;
    use sui::vec_map::{Self, VecMap};
    use std::type_name::{Self, TypeName};
    use token::deep::DEEP;

    //// ====== Constants ====== ////
    /// Protocol
    const CURRENT_VERSION: u64 = 1;
    const EARLY_WITHDRAWAL_TIMEOUT: u64 = 1000 * 60 * 60 * 24; // 1 day in milliseconds

    /// --- Oracle --- ///
    // Max age of a Pyth price in seconds
    const PYTH_MAX_AGE: u64 = 20;
    const MAX_PRICE_CONF_BPS: u64 = 100; // 1% = 100 BPS

    // Decimals
    const USDC_DECIMALS: u64    = 6;
    const TD_WEIGHT_SCALE: u64  = 100_000_000;
    
    //// --- Getter --- ////
    public fun GET_CURRENT_VERSION(): u64 { CURRENT_VERSION }
    public fun GET_PYTH_MAX_AGE(): u64 { PYTH_MAX_AGE }
    public fun GET_USDC_DECIMALS(): u64 { USDC_DECIMALS }
    public fun GET_TD_WEIGHT_SCALE(): u64 { TD_WEIGHT_SCALE }
    public fun GET_MAX_PRICE_CONF_BPS(): u64 { MAX_PRICE_CONF_BPS }
    public fun GET_EARLY_WITHDRAWAL_TIMEOUT(): u64 { EARLY_WITHDRAWAL_TIMEOUT }
}