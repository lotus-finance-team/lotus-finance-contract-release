# Design Ideas about Ticket
> Heavily borrowed from KKlas's code.

In Sui there's a widely adopted yet poorly documented technieque "Hot Potato" design pattern. 
To me it's more like a iteration that you can't implement on contract side alone. 
Sometimes due to account and typing parameter limit, you can't list everything within one transaction. 
You need to compose and iterate the operations from client side. Then it is contract's obligation to verify 
the iteration is complete and sufficient. Here I'd use hot potato.

```
    // Hot Potato Ticket
    // Use this ticket to ensure atomicity of create_incenvized_db_vault.
    public struct LotusLPFarmCreatePoolTicket {
        key_id: ID,
        usd_value: u64,
        td_farm_keys: VecSet<String>,
    }


    //// ====== Vault Operations ====== ////
    // Create LotusLPFarmCreatePoolTicket
    public fun new_create_pool_ticket<LP>(self: &LotusLPFarm<LP>, usd_value: u64): LotusLPFarmCreatePoolTicket {
        LotusLPFarmCreatePoolTicket {
            key_id: object::id(self),
            usd_value: usd_value,
            td_farm_keys: vec_set::empty(),
        }
    }
    // Destroy LotusLPFarmCreatePoolTicket
    public fun destroy_create_pool_ticket<LP>(self: &mut LotusLPFarm<LP>, create_pool_ticket: LotusLPFarmCreatePoolTicket) {
        assert!(create_pool_ticket.key_id == object::id(self), EInvalidTicketKey);
        assert!(create_pool_ticket.td_farm_keys.size() == self.td_farm_keys.size(), EinvalidTicketLength);
        let LotusLPFarmCreatePoolTicket { key_id, usd_value, td_farm_keys } = create_pool_ticket;
    }
    // Vault insertion into member TDFarm 
    public fun add_incentivized_db_vault_to_td_farm_with_ticket<LP, Incentive>(
        self: &mut LotusLPFarm<LP>, 
        vault: &mut LotusDBVault<LP>,
        create_pool_ticket: &mut LotusLPFarmCreatePoolTicket,
        clock: &Clock,
    ) {
        let coin_key: String = type_name::get<Incentive>().into_string();
        assert!(!create_pool_ticket.td_farm_keys.contains(&coin_key), EInvalidTicketKey);
        create_pool_ticket.td_farm_keys.insert(coin_key);
        let td_farm: &mut TDFarm<Incentive> = &mut self.td_farms[coin_key];
        let td_farm_admin_cap: &TDFarmAdminCap = &self.td_farm_admin_caps[coin_key];
        vault.add_to_td_farm(td_farm, td_farm_admin_cap, create_pool_ticket.usd_value as u32, clock);
    }
```

Here we start the iteration operation using `new_create_pool_ticket`, and use the `add_incentivized_db_vault_to_td_farm_with_ticket` function to add vault to each `td_farm`, the ticket will verify the operation is complete.

```
    let (mut vault3, mut ticket) = lp_farm.create_incentivized_db_vault<LOTUS_LP_FARM_TESTS, MY_USDC>(
        id_from_address(@0x3333),
        mint_for_testing<MY_USDC>(100, test.ctx()),
        &clock, 
        test.ctx()
    );
    lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LOTUS_LP_FARM_TESTS, FOO>(&mut vault3, &mut ticket, &clock);
    lp_farm.add_incentivized_db_vault_to_td_farm_with_ticket<LOTUS_LP_FARM_TESTS, BAR>(&mut vault3, &mut ticket, &clock);
    lp_farm.destroy_create_pool_ticket(ticket);
```