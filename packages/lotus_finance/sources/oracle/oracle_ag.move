module lotus_finance::oracle_ag {
    use std::type_name::{Self, TypeName};
    use std::ascii::String;
    use std::string::{Self as STD_STRING};
    use std::debug;
    use sui::package;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use lotus_finance::consts::{Self, GET_PYTH_MAX_AGE};
    use lotus_finance::lotus_math::{Self, mul, mul_u128, scale_to_float, scale_from_float};
    use pyth::{pyth, price_info::{Self, PriceInfoObject}, price_identifier, price};

    //// ====== Configs ====== ////
    /// Price config flag logics:
    ///   - CZERO_VALUE: asset always treated as zero value  // Deprecated
    ///   - CPYTH_PRICE: asset price is fetched from Pyth
    ///   - CSWITCHBOARD_PRICE: asset price is fetched from Switchboard
    ///   (When multiple oracle flags are present, should combine the price from multiple oracles)
    const CPYTH_PRICE: u64 = 1 << 10;

    public fun GET_CPYTH_PRICE(): u64 { CPYTH_PRICE }

    //// ====== Errors ====== ////
    const EInvalidPriceFeed: u64 = 0;
    const EInvalidDecimal: u64 = 1;
    const EInvalidConfidence: u64 = 2;

    //// ====== Structs ====== ////
    public struct OracleAggregator has key {
        id: UID,
        pyth_price_id_table: Table<String, vector<u8>>,
        coin_decimal_registry: Table<String, u8>,
        max_age: u64,
        coin_config: Table<String, u64>,
    }

    public struct OracleAggregatorCap has key, store {
        id: UID,
        oracle_aggregator: ID,
    }

    public struct ORACLE_AG has drop {}

    //// ====== Utils ====== ////
    public fun assert_oracle_aggregator_cap(
        self: &OracleAggregator,
        cap: &OracleAggregatorCap,
    ) {
        assert!(object::id(self) == cap.oracle_aggregator);
    }

    public fun assert_price_object_type<T>(self: &OracleAggregator, price_info_object: &PriceInfoObject) {
        let coin_key = type_name::get<T>().into_string();
        assert!(self.pyth_price_id_table.contains(coin_key), EInvalidPriceFeed);
        let price_info = price_info_object.get_price_info_from_price_info_object();
        let price_id = self.pyth_price_id_table[coin_key];
        assert!(price_info.get_price_identifier().get_bytes() == price_id, EInvalidPriceFeed);
    }

    public fun get_coin_decimal<T>(self: &OracleAggregator): u8 {
        let coin_key = type_name::get<T>().into_string();
        assert!(self.coin_decimal_registry.contains(coin_key), EInvalidPriceFeed);
        self.coin_decimal_registry[coin_key]
    }

    // Utility function for calculating USD value for a given amount of a token.
    // Params:
    // - amount: Amount of token, native decimal representation
    // Return:
    // - USD value of the token amount, USDC decimal representation (6 decimals)
    public fun calc_usd_value<T>(self: &OracleAggregator, price_info_object: &PriceInfoObject, amount: u64, clock: &Clock): u64 {
        assert_price_object_type<T>(self, price_info_object);
        let coin_decimal = self.get_coin_decimal<T>() as u64;
        let (price, price_decimal, _) = self.get_price<T>(price_info_object, clock);
        let (amount_float, price_float) = (scale_to_float(amount, coin_decimal), scale_to_float(price, price_decimal));
        scale_from_float(mul_u128(amount_float, price_float), consts::GET_USDC_DECIMALS())
    }
    
    //// ====== Constructors ====== ////
    fun new(ctx: &mut TxContext): (OracleAggregator, OracleAggregatorCap) {
        let ag = OracleAggregator {
            id: object::new(ctx),
            pyth_price_id_table: table::new(ctx),
            coin_decimal_registry: table::new(ctx),
            coin_config: table::new(ctx),
            max_age: GET_PYTH_MAX_AGE(),
        };
        let ag_cap = OracleAggregatorCap {
            id: object::new(ctx),
            oracle_aggregator: object::id(&ag),
        };
        (ag, ag_cap)
    }

    //// ====== Operations ====== ////
    fun init(otw: ORACLE_AG, ctx: &mut TxContext) {
        let (ag, ag_cap) = new(ctx);
        transfer::share_object(ag);
        transfer::transfer(ag_cap, tx_context::sender(ctx));
        package::claim_and_keep(otw, ctx);
    }

    public fun update_pyth_price_id<T>(
        self: &mut OracleAggregator,
        cap: &OracleAggregatorCap,
        price_id: vector<u8>,
    ) {
        assert_oracle_aggregator_cap(self, cap);
        if (!self.pyth_price_id_table.contains(type_name::get<T>().into_string())) {
            self.pyth_price_id_table.add(type_name::get<T>().into_string(), price_id);
        } else {
            let current_price_id = self.pyth_price_id_table.borrow_mut(type_name::get<T>().into_string());
            *current_price_id = price_id;
        }
    }

    public fun update_coin_config<T>(
        self: &mut OracleAggregator,
        cap: &OracleAggregatorCap,
        config: u64,
    ) {
        assert_oracle_aggregator_cap(self, cap);
        if (!self.coin_config.contains(type_name::get<T>().into_string())) {
            self.coin_config.add(type_name::get<T>().into_string(), config);
        } else {
            let current_config = self.coin_config.borrow_mut(type_name::get<T>().into_string());
            *current_config = config;
        }
    }

    public fun update_coin_decimal<T>(
        self: &mut OracleAggregator,
        cap: &OracleAggregatorCap,
        decimal: u8,
    ) {
        assert_oracle_aggregator_cap(self, cap);
        if (!self.coin_decimal_registry.contains(type_name::get<T>().into_string())) {
            self.coin_decimal_registry.add(type_name::get<T>().into_string(), decimal);
        };
        let current_decimal = self.coin_decimal_registry.borrow_mut(type_name::get<T>().into_string());
        *current_decimal = decimal;
    }

    //// ====== Inspection Functions ====== ////
    public fun get_pyth_address<T>(self: &OracleAggregator): vector<u8> { self.pyth_price_id_table[type_name::get<T>().into_string()] }
    
    public fun get_price<T>(
        self: &OracleAggregator,
        price_info_object: &PriceInfoObject,
        clock: &Clock
    ): (u64, u64, u64) {
        let price_struct = pyth::get_price_no_older_than(price_info_object, clock, self.max_age);
        let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
        let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
        // Security check
        let coin_key = type_name::get<T>().into_string();
        assert!(self.pyth_price_id_table.contains(coin_key), EInvalidPriceFeed);
        assert!(price_id == self.pyth_price_id_table[coin_key], EInvalidPriceFeed);

        let price_i64 = price::get_price(&price_struct);
        let expo_i64 = price::get_expo(&price_struct);
        let confidence = price::get_conf(&price_struct);
        let timestamp_sec = price::get_timestamp(&price_struct);

        if (expo_i64.get_is_negative() == true) {
            let price = price_i64.get_magnitude_if_positive();
            let decimal = expo_i64.get_magnitude_if_negative();
            assert!(confidence < price * consts::GET_MAX_PRICE_CONF_BPS() / 10000, EInvalidConfidence);
            (price, decimal, timestamp_sec)
        } else {
            let price = price_i64.get_magnitude_if_positive() * 10u64.pow(expo_i64.get_magnitude_if_positive() as u8);
            let decimal = 0;
            assert!(confidence < price * consts::GET_MAX_PRICE_CONF_BPS() / 10000, EInvalidConfidence);
            (price, decimal, timestamp_sec)
        }
    }

    #[test_only]
    public fun init_test(ctx: &mut TxContext) {
        init(ORACLE_AG {}, ctx);
    }

    #[test_only]
    public fun get_price_test<T>(
        self: &OracleAggregator,
        price_info_object: &PriceInfoObject,
        clock: &Clock
    ): (u64, u64, u64) {
        (100, 100, 100)
    }
}