module lotus_finance::lotus_lp_farm {
    use std::debug;
    use std::type_name::{Self, TypeName};
    use std::ascii::String;
    use sui::vec_set::{Self, VecSet};
    use sui::vec_map::{Self, VecMap};
    use sui::bag::{Self, Bag};
    use sui::clock::Clock;
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use std::string::{Self as STD_STRING};
    use usdc::usdc::USDC;
    use pyth::price_info::{Self, PriceInfoObject};
    use token::deep::DEEP;
    use deepbook::pool::{Self as db_pool, Pool as DBPool};
    use token_distribution::farm::{Self, Farm as TDFarm, AdminCap as TDFarmAdminCap};
    use lotus_finance::consts::{Self as LOTUS_CONSTS};
    use lotus_finance::lotus_db_vault::{Self, LotusDBVault, LotusDBVaultCap, TopUpTicket};
    use lotus_finance::oracle_ag::{Self, OracleAggregator, assert_price_object_type};
    use lotus_finance::lotus_config::{Self, LotusConfig};
    use lotus_finance::lotus_db_vault::assert_vault_cap_access;

    // Lotus LP Farm struct. For a category of strategies. 
    // LP Farm is incentivized on TVL basis
    public struct LotusLPFarm<phantom LP> has key, store {
        id: UID,
        // --- TD Farm Config ---//
        td_farm_keys: VecSet<String>,
        td_farms: Bag,
        td_farm_admin_caps: Bag,
        // --- Native Farm Config ---//
        allowed_deposit_asset: VecSet<String>, // Allowed deposit asset
        banned_vault_ids: VecSet<ID>, // Banned vaults
        // --- Vault Config ---//
        vault_ids: VecSet<ID>,
        vault_td_farm_member_ids: VecMap<ID, ID>,
        vault_tvls: VecMap<ID, u64>,
        allowed_db_pools: VecSet<ID>,
        max_tvl: u64,
        min_vault_usd_value: u64,
    }

    public struct LotusLPFarmCap has key, store {
        id: UID,
        farm_id: ID,
    }

    /// --- Hot Potato Ticket --- ///
    // Use this ticket to ensure atomicity of create_incenvized_db_vault.
    public struct LotusLPFarmCreateVaultTicket {
        key_id: ID,
        usd_value: u64,
        td_farm_keys: VecSet<String>,
    }
    public struct LotusLPFarmCloseVaultTicket {
        key_id: ID,
        td_farm_keys: VecSet<String>,
    }
    // Update TD pool weight ticket
    // Only constrains atomicity of Vaults per TD Farm update.
    public struct LotusLPFarmUpdatePoolWeightTicket {
        key_id: ID,
        td_farm_id: ID,
        vault_ids: VecSet<ID>,
    }

    //// ====== Events ====== ////
    public struct CreateLPFarmEvent has copy, drop {
        farm_id: ID,
        farm_cap_id: ID,
    } 

    // Event type, e.g. 
    // - "add/remove_allowed_deposit_asset",    - 1, 2
    // - "add/remove_allowed_db_pool",          - 3, 4
    // - "add/remove_banned_vaults",            - 5, 6
    // - "update_unlock_rate",                  - 10
    // - "update_max_tvl",                      - 11
    // - "update_min_vault_usd_value"           - 12
    public struct UpdateLPFarmEvent has copy, drop {
        farm_id: ID,
        event_type: u8, 
    }
    
    public struct CreateIncentivizedDBVaultEvent has copy, drop {
        farm_id: ID,
        balance_manager_id: ID,
        allowed_db_pool_id: ID,
        base_deposit_type: TypeName,
        base_deposit_value: u64,
        quote_deposit_type: TypeName,
        quote_deposit_value: u64,
        vault_id: ID,
        vault_creator_cap_id: ID,
        vault_trade_cap_id: ID,
    }

    public struct TopUpFarmIncentiveEvent has copy, drop {
        farm_id: ID,
        td_farm_id: ID,
        coin_type: TypeName,
        top_up_value: u64,
    }

    public struct UpdateVaultWeightEvent has copy, drop {
        farm_id: ID,
        vault_id: ID,
        usd_value: u64,
    }

    //// ====== Error Codes ====== ////
    // Farm already exists
    const ETDFarmAlreadyExists: u64 = 0;
    const EInvalidTicketKey: u64 = 1;
    const EinvalidTicketLength: u64 = 2;
    const EInvalidAssetType: u64 = 4;
    const EInvalidDBPool: u64 = 5;
    const EMaxTVLExceeds: u64 = 6;
    const EVaultValueTooLow: u64 = 7;
    const EVaultNotEmpty: u64 = 9;
    const EInvalidTicket: u64 = 10;

    // Helper function, key object from type.
    public struct CoinKey<phantom T> has store, copy, drop {}
    
    public fun new<LP>(ctx: &mut TxContext): (LotusLPFarm<LP>, LotusLPFarmCap) {
        let mut farm = LotusLPFarm<LP> {
            id: object::new(ctx),
            td_farm_keys: vec_set::empty(),
            td_farms: bag::new(ctx),
            td_farm_admin_caps: bag::new(ctx),
            // lp_treasury: treasury,
            allowed_deposit_asset: vec_set::empty(),
            banned_vault_ids: vec_set::empty(),
            vault_ids: vec_set::empty(),
            vault_td_farm_member_ids: vec_map::empty(),
            vault_tvls: vec_map::empty(),
            allowed_db_pools: vec_set::empty(),
            max_tvl: std::u64::max_value!(),
            min_vault_usd_value: 0,
        };
        let farm_cap = LotusLPFarmCap {
            id: object::new(ctx),
            farm_id: object::id(&farm)
        };

        // Emit event
        event::emit(CreateLPFarmEvent {
            farm_id: object::id(&farm),
            farm_cap_id: object::id(&farm_cap),
        });

        (farm, farm_cap)
    }

    public fun add_allowed_db_pool<LP, Base, Quote>(self: &mut LotusLPFarm<LP>, cap: &LotusLPFarmCap, db_pool: &DBPool<Base, Quote>) {
        assert_farm_cap(self, cap);
        vec_set::insert(&mut self.allowed_db_pools, object::id(db_pool));

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 3, // Add allowed DB pool
        });
    }

    public fun remove_allowed_db_pool<LP>(self: &mut LotusLPFarm<LP>, cap: &LotusLPFarmCap, pool_id: ID) {
        assert_farm_cap(self, cap);
        vec_set::remove(&mut self.allowed_db_pools, &pool_id);

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 4, // Remove allowed DB pool
        });
    }

    public fun update_max_tvl<LP>(self: &mut LotusLPFarm<LP>, cap: &LotusLPFarmCap, value: u64) {
        assert_farm_cap(self, cap);
        self.max_tvl = value;
        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 11, // Update max TVL
        });
    }

    public fun update_min_vault_usd_value<LP>(self: &mut LotusLPFarm<LP>, cap: &LotusLPFarmCap, value: u64) {
        assert_farm_cap(self, cap);
        self.min_vault_usd_value = value;
        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 12, // Update min vault USD value
        });
    }

    //// ====== TD Farm Operations ====== ////
    // Add a TD_Farm. TD_Farm is unique by `Incentive` type.
    // Check if `Incentive` already exists before calling this.
    public fun add_td_farm<LP, Incentive>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap, unlock_start_ts_sec: u64, ctx: &mut TxContext) {
        assert_farm_cap(self, lp_farm_admin_cap);
        let balance = balance::zero<Incentive>();
        let (mut td_farm, td_farm_admin_cap): (TDFarm<Incentive>, TDFarmAdminCap) = farm::create<Incentive>(balance, unlock_start_ts_sec, ctx);
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(!self.td_farm_keys.contains(&coin_key), ETDFarmAlreadyExists);
        self.td_farm_keys.insert(coin_key);
        self.td_farms.add(coin_key, td_farm);
        self.td_farm_admin_caps.add(coin_key, td_farm_admin_cap);
    }

    public fun top_up_incentive_balance<LP, Incentive>(
        self: &mut LotusLPFarm<LP>, 
        coin: Coin<Incentive>,
        clock: &Clock,
    ) {
        let farm_id = object::id(self);
        let coin_key: String = type_name::get<Incentive>().into_string();
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        let td_farm_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        
        // Emit event
        event::emit(TopUpFarmIncentiveEvent {
            farm_id: farm_id,
            td_farm_id: object::id(td_farm),
            coin_type: type_name::get<Incentive>(),
            top_up_value: coin.value(),
        });
        
        farm::top_up_balance<Incentive>(td_farm_cap, td_farm, coin.into_balance(), clock);
    }

    public fun set_farm_unlock_rate<LP, Incentive>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap, value: u64, clock: &Clock, ctx: &mut TxContext) {
        assert_farm_cap(self, lp_farm_admin_cap);
        let coin_key: String = type_name::get<Incentive>().into_string();
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        farm::change_unlock_per_second(td_farm_admin_cap, td_farm, value, clock);

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 10, // Update unlock rate
        });
    }

    public fun add_allowed_deposit_asset<LP, T>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap){
        assert_farm_cap(self, lp_farm_admin_cap);
        let asset_name = type_name::get<T>().into_string();
        vec_set::insert(&mut self.allowed_deposit_asset, asset_name);

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 1, // Add allowed deposit asset
        });
    }

    public fun remove_allowed_deposit_asset<LP, T>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap){
        assert_farm_cap(self, lp_farm_admin_cap);
        let asset_name = type_name::get<T>().into_string();
        vec_set::remove(&mut self.allowed_deposit_asset, &asset_name);

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 2, // Remove allowed deposit asset
        });
    }

    public fun add_banned_vault<LP>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap, vault: &LotusDBVault<LP>) {
        let vault_id = object::id(vault);
        assert_farm_cap(self, lp_farm_admin_cap);
        if (!self.banned_vault_ids.contains(&vault_id)) {
            vec_set::insert(&mut self.banned_vault_ids, vault_id);
        };

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 5, // Add banned vault
        });
    }

    public fun remove_banned_vault<LP>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap, vault: &LotusDBVault<LP>) {
        let vault_id = object::id(vault);
        assert_farm_cap(self, lp_farm_admin_cap);
        vec_set::remove(&mut self.banned_vault_ids, &vault_id);

        event::emit(UpdateLPFarmEvent {
            farm_id: object::id(self),
            event_type: 6, // Remove banned vault
        });
    }

    //// ====== Vault Operations ====== ////
    // Create LotusLPFarmCreateVaultTicket
    fun new_create_pool_ticket<LP>(self: &LotusLPFarm<LP>, usd_value: u64): LotusLPFarmCreateVaultTicket {
        LotusLPFarmCreateVaultTicket {
            key_id: object::id(self),
            usd_value: usd_value,         // USD value in USDC decimal representation, 6 decimals
            td_farm_keys: vec_set::empty(),
        }
    }
    // Destroy LotusLPFarmCreateVaultTicket
    public fun destroy_create_pool_ticket<LP>(self: &mut LotusLPFarm<LP>, create_vault_ticket: LotusLPFarmCreateVaultTicket) {
        assert!(create_vault_ticket.key_id == object::id(self), EInvalidTicketKey);
        assert!(create_vault_ticket.td_farm_keys.size() == self.td_farm_keys.size(), EinvalidTicketLength);
        let LotusLPFarmCreateVaultTicket { key_id, usd_value, td_farm_keys } = create_vault_ticket;
    }
    fun new_close_vault_ticket<LP>(self: &LotusLPFarm<LP>): LotusLPFarmCloseVaultTicket {
        LotusLPFarmCloseVaultTicket {
            key_id: object::id(self),
            td_farm_keys: vec_set::empty(),
        }
    }
    public fun destroy_close_vault_ticket<LP>(self: &mut LotusLPFarm<LP>, close_pool_ticket: LotusLPFarmCloseVaultTicket) {
        assert!(close_pool_ticket.key_id == object::id(self), EInvalidTicketKey);
        assert!(close_pool_ticket.td_farm_keys.size() == self.td_farm_keys.size(), EinvalidTicketLength);
        let LotusLPFarmCloseVaultTicket { key_id, td_farm_keys } = close_pool_ticket;
    }
    // Vault insertion into member TDFarm 
    public fun add_incentivized_db_vault_to_td_farm_with_ticket<LP, Incentive>(
        self: &mut LotusLPFarm<LP>, 
        vault: &mut LotusDBVault<LP>,
        create_vault_ticket: &mut LotusLPFarmCreateVaultTicket,
        clock: &Clock,
    ) {
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(!create_vault_ticket.td_farm_keys.contains(&coin_key), EInvalidTicketKey);
        create_vault_ticket.td_farm_keys.insert(coin_key);
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        debug::print(&create_vault_ticket.usd_value);
        let mut weight = (create_vault_ticket.usd_value / LOTUS_CONSTS::GET_TD_WEIGHT_SCALE()) as u32;
        if (weight == 0) {
            weight = 1;
        };
        vault.add_to_td_farm(td_farm, td_farm_admin_cap, weight, clock);
    }
    // Create incentivized vault. All vaults gets incentive should be created with this function.
    // Creating using lotus_db_vault::new is not getting incentives from LotusLPFarm.
    // - Types:
    //      LP: LP stake type
    //      T: Initial deposit token type
    // - Returns:
    //      LotusDBVault: Created vault
    //      LotusDBVaultCap: Vault capability
    //      LotusLPFarmCreateVaultTicket: Ticket to ensure atomicity of create_incentivized_db_vault
    //      
    public fun create_incentivized_db_vault<LP, Base, Quote>(
        lotus_lp_farm: &mut LotusLPFarm<LP>,
        lotus_config: &LotusConfig,
        allowed_pool: &DBPool<Base, Quote>,
        coin_base: Coin<Base>,
        coin_quote: Coin<Quote>,
        oracle_ag: &OracleAggregator,
        base_info_object: &PriceInfoObject,
        quote_info_object: &PriceInfoObject,
        time: &Clock, 
        ctx: &mut TxContext
    ): (LotusDBVault<LP>, LotusDBVaultCap, LotusDBVaultCap, LotusLPFarmCreateVaultTicket) {
        // Checks
        let allowed_pool_id = object::id(allowed_pool);
        assert_allowed_db_pool(lotus_lp_farm, allowed_pool_id);
        lotus_lp_farm.assert_deposit_asset_type<LP, Base>();
        lotus_lp_farm.assert_deposit_asset_type<LP, Quote>();
        oracle_ag::assert_price_object_type<Base>(oracle_ag, base_info_object);
        oracle_ag::assert_price_object_type<Quote>(oracle_ag, quote_info_object);
        lotus_config.assert_current_version();
        lotus_config::assert_protocol_status_ok(lotus_config);
        // Calculate deposit value
        let coin_base_value = coin_base.value();
        let coin_quote_value = coin_quote.value();
        let coin_base_usd_value = oracle_ag::calc_usd_value<Base>(oracle_ag, base_info_object, coin_base.value(), time);
        let coin_quote_usd_value = oracle_ag::calc_usd_value<Quote>(oracle_ag, quote_info_object, coin_quote.value(), time);
        let deposit_value = coin_base_usd_value + coin_quote_usd_value;
        // Create vault
        let (mut vault, vault_creator_cap, vault_trade_cap) = lotus_db_vault::new_for_pooling<LP>(allowed_pool_id, deposit_value, time, ctx);
        lotus_lp_farm.vault_ids.insert(object::id(&vault));
        lotus_lp_farm.vault_td_farm_member_ids.insert(object::id(&vault), vault.get_td_farm_member_key_id());
        assert!(deposit_value >= lotus_lp_farm.min_vault_usd_value, EVaultValueTooLow);
        debug::print(&STD_STRING::utf8(b"Create Incentivized DB Vault at initial value: "));
        debug::print(&deposit_value);
        lotus_lp_farm.assert_deposit_asset_type<LP, Base>();
        lotus_lp_farm.assert_deposit_asset_type<LP, Quote>();
        vault.deposit(coin_base, ctx);
        vault.deposit(coin_quote, ctx);
        let create_pool_ticket = lotus_lp_farm.new_create_pool_ticket(deposit_value);

        // Remaining deposit value update
        assert!(lotus_lp_farm.get_vault_tvls_sum() + deposit_value <= lotus_lp_farm.max_tvl, EMaxTVLExceeds);
        lotus_lp_farm.vault_tvls.insert(object::id(&vault), deposit_value);

        // Emit event
        event::emit(CreateIncentivizedDBVaultEvent {
            farm_id: object::id(lotus_lp_farm),
            balance_manager_id: vault.balance_manager_id(),
            allowed_db_pool_id: allowed_pool_id,
            base_deposit_type: type_name::get<Base>(),
            base_deposit_value: coin_base_value,
            quote_deposit_type: type_name::get<Quote>(),
            quote_deposit_value: coin_quote_value,
            vault_id: object::id(&vault),
            vault_creator_cap_id: object::id(&vault_creator_cap),
            vault_trade_cap_id: object::id(&vault_trade_cap),
        });

        (vault, vault_creator_cap, vault_trade_cap, create_pool_ticket)
    }

    // Deprecated
    #[test_only]
    public fun close_vault_deprecated<LP, Base, Quote>(
        self: &mut LotusLPFarm<LP>,
        vault: &mut LotusDBVault<LP>,
        vault_cap: &LotusDBVaultCap,
        lotus_config: &LotusConfig,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_ag: &OracleAggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>, Coin<DEEP>, LotusLPFarmCloseVaultTicket) {
        // Checks
        lotus_config.assert_current_version();
        lotus_config::assert_protocol_status_ok(lotus_config);
        // Redeem
        let (coin_base, coin_quote, coin_deep) = vault.redeem_all_token_base_quote_deep(
            vault_cap, 
            lotus_config,
            pool, 
            base_price_info_object, 
            quote_price_info_object, 
            deep_price_info_object, 
            oracle_ag, 
            clock, 
            ctx
        );
        // Remove vault from farm
        self.vault_ids.remove(&object::id(vault));
        self.vault_tvls.remove(&object::id(vault));
        self.vault_td_farm_member_ids.remove(&object::id(vault));
        let close_pool_ticket = self.new_close_vault_ticket();

        (coin_base, coin_quote, coin_deep, close_pool_ticket)
        
    }

    public fun close_vault_permissionless<LP>(
        self: &mut LotusLPFarm<LP>,
        vault: &LotusDBVault<LP>,
    ): LotusLPFarmCloseVaultTicket {
        assert!(vault.get_shareholder_address_vec().length() == 0, EVaultNotEmpty);
        self.new_close_vault_ticket()
    }

    public fun remove_farm_key_from_td_farm<LP, Incentive>(
        self: &mut LotusLPFarm<LP>,
        vault: &mut LotusDBVault<LP>,
        ticket: &mut LotusLPFarmCloseVaultTicket,
        clock: &Clock
    ) {
        let coin_key = type_name::get<Incentive>().into_string();
        vault.remove_farm_key_from_td_farm<LP, Incentive>(&mut self.td_farms[coin_key], clock);
        ticket.td_farm_keys.insert(coin_key);
    }

    // TD pool top_up operation
    public fun top_up_to_td_pool<LP, Incentive>(
        self: &mut LotusLPFarm<LP>,
        vault: &mut LotusDBVault<LP>,
        top_up_ticket: &mut lotus_db_vault::TopUpTicket,
        clock: &Clock
    ) {
        let coin_key: String = type_name::get<Incentive>().into_string();
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        lotus_db_vault::td_pool_top_up(td_farm, vault, top_up_ticket, clock);
    }

    public fun create_update_vault_weight_ticket<LP, Incentive>(self: &LotusLPFarm<LP>): LotusLPFarmUpdatePoolWeightTicket {
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        LotusLPFarmUpdatePoolWeightTicket {
            key_id: object::id(self),
            td_farm_id: object::id(td_farm),
            vault_ids: vec_set::empty(),
        }
    }

    public fun destroy_update_vault_weight_ticket<LP, Incentive>(self: &mut LotusLPFarm<LP>, update_vault_weight_ticket: LotusLPFarmUpdatePoolWeightTicket) {
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        assert!(update_vault_weight_ticket.key_id == object::id(self), EInvalidTicket);
        assert!(update_vault_weight_ticket.td_farm_id == object::id(td_farm), EInvalidTicket);
        // Check set equality
        assert!(update_vault_weight_ticket.vault_ids.size() == self.vault_ids.size(), EinvalidTicketLength);
        let mut i: u64 = 0;
        while (i < update_vault_weight_ticket.vault_ids.size()) {
            let vault_id = self.vault_ids.keys()[i];
            assert!(update_vault_weight_ticket.vault_ids.contains(&vault_id), EInvalidTicket);
            i = i + 1;
        };
        
        let LotusLPFarmUpdatePoolWeightTicket { key_id, td_farm_id, vault_ids } = update_vault_weight_ticket;
    }

    // Iterate through all incentive types `Incentive` from client side.
    public fun update_vault_weight_with_ticket<LP, Incentive, Base, Quote>(
        self: &mut LotusLPFarm<LP>,
        vault: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        deep_price_info_object: &PriceInfoObject,
        oracle_ag: &OracleAggregator,
        update_vault_weight_ticket: &mut LotusLPFarmUpdatePoolWeightTicket,
        clock: &Clock
    ) {
        lotus_db_vault::assert_db_pool(vault, pool);
        assert_price_object_type<Base>(oracle_ag, base_price_info_object);
        assert_price_object_type<Quote>(oracle_ag, quote_price_info_object);
        assert_price_object_type<DEEP>(oracle_ag, deep_price_info_object);
        // Assert ticket
        assert!(update_vault_weight_ticket.key_id == object::id(self), EInvalidTicket);

        let mut weight: u32 = 0;
        let mut usd_value: u64 = 0;
        if (self.banned_vault_ids.contains(&object::id(vault))) {
            usd_value = 0;
            weight = 1;    
        } else {
            usd_value = vault.get_total_usd_value(
                pool, 
                base_price_info_object, 
                quote_price_info_object, 
                deep_price_info_object, 
                oracle_ag, 
                clock
            );
            weight = (usd_value / LOTUS_CONSTS::GET_TD_WEIGHT_SCALE()) as u32;
        };
        if (weight == 0) {
            weight = 1;
        };
        let td_farm_member_key = self.vault_td_farm_member_ids[&object::id(vault)];

        let coin_key = type_name::get<Incentive>().into_string();
        debug::print(&coin_key);
        debug::print(&self.td_farms.length());
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        assert!(update_vault_weight_ticket.td_farm_id == object::id(td_farm), EInvalidTicket);
        let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        farm::change_member_weight(td_farm_admin_cap, td_farm, td_farm_member_key, weight, clock);
        if (self.vault_tvls.contains(&object::id(vault))) {
            let mut value0 = self.vault_tvls.get_mut(&object::id(vault));
            *value0 = usd_value;
        } else {
            self.vault_tvls.insert(object::id(vault), usd_value);
        };
        update_vault_weight_ticket.vault_ids.insert(object::id(vault));

        // Emit event
        event::emit(UpdateVaultWeightEvent {
            farm_id: object::id(self),
            vault_id: object::id(vault),
            usd_value: usd_value,
        });
    }

    // Update vault weight to zero if vault is out of range.
    public fun update_zero_weight_oor_vault<LP, Incentive, Base, Quote>(
        self: &mut LotusLPFarm<LP>,
        vault: &LotusDBVault<LP>,
        pool: &DBPool<Base, Quote>,
        base_price_info_object: &PriceInfoObject,
        quote_price_info_object: &PriceInfoObject,
        ag: &OracleAggregator,
        clock: &Clock,
    ) {
        if (!vault.is_strategy_in_range<LP, Base, Quote>(pool, base_price_info_object, quote_price_info_object, ag, clock)) {
            // Vault is out of range, set zero weight
            let coin_key = type_name::get<Incentive>().into_string();
            assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
            let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
            let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
            let td_farm_member_key = self.vault_td_farm_member_ids[&object::id(vault)];
            farm::change_member_weight(td_farm_admin_cap, td_farm, td_farm_member_key, 1, clock);
        }
    }


    //// ====== Inspection Functions ====== ////
    public fun td_farm_length<LP>(self: &LotusLPFarm<LP>): u64 { self.td_farm_keys.size() }
    public fun td_farm_contains<LP, Incentive>(self: &LotusLPFarm<LP>): bool { let coin_key: String = type_name::get<Incentive>().into_string(); self.td_farm_keys.contains(&coin_key) }
    public fun td_farm_unlock_rate<LP, Incentive>(self: &LotusLPFarm<LP>): u64 { 
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        td_farm.get_unlock_per_second()
    }

    public fun td_farm_unlock_start_ts_sec<LP, Incentive>(self: &LotusLPFarm<LP>): u64 { 
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        td_farm.get_unlock_start_ts_sec()
    }

    public fun td_farm_final_unlock_ts_sec<LP, Incentive>(self: &LotusLPFarm<LP>): u64 { 
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        td_farm.get_final_unlock_ts_sec()
    }

    public fun td_farm_remaining_unlock<LP, Incentive>(self: &LotusLPFarm<LP>, clock: &Clock): u64 { 
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(self.td_farm_keys.contains(&coin_key), EInvalidAssetType);
        let td_farm: &TDFarm<Incentive> = &self.td_farms[coin_key];
        td_farm.get_remaining_unlock(clock)
    }

    public fun get_max_tvl<LP>(self: &LotusLPFarm<LP>): u64 { self.max_tvl }

    public fun get_min_vault_usd_value<LP>(self: &LotusLPFarm<LP>): u64 { self.min_vault_usd_value }

    public fun get_vault_tvls_sum<LP>(self: &LotusLPFarm<LP>): u64 {
        let mut sum: u64 = 0;
        let mut i: u64 = 0;
        while (i < self.vault_tvls.size()) {
            let (_, value) = self.vault_tvls.get_entry_by_idx(i);
            sum = sum + *value;
            i = i + 1;
        };
        sum
    }

    //// ====== Utility Functions ====== ////
    fun assert_farm_cap<LP>(self: &LotusLPFarm<LP>, cap: &LotusLPFarmCap) {
        assert!(object::id(self) == cap.farm_id);
    }
    fun assert_allowed_db_pool<LP>(self: &LotusLPFarm<LP>, pool_id: ID) {
        assert!(vec_set::contains(&self.allowed_db_pools, &pool_id), EInvalidDBPool);
    }
    fun assert_deposit_asset_type<LP, T>(self: &LotusLPFarm<LP>) {
        let asset_name = type_name::get<T>().into_string();
        assert!(vec_set::contains(&self.allowed_deposit_asset, &asset_name), EInvalidAssetType);
    }

    #[test_only]
    public fun add_td_farm_for_test<LP, Incentive>(self: &mut LotusLPFarm<LP>, lp_farm_admin_cap: &LotusLPFarmCap, unlock_start_ts_sec: u64, ctx: &mut TxContext) { self.add_td_farm<LP, Incentive>(lp_farm_admin_cap, unlock_start_ts_sec, ctx); }
    #[test_only]
    public fun vault_ids<LP>(self: &LotusLPFarm<LP>): VecSet<ID> { self.vault_ids }
    #[test_only]
    public fun vault_td_farm_member_ids<LP>(self: &LotusLPFarm<LP>): VecMap<ID, ID> { self.vault_td_farm_member_ids }
    
}