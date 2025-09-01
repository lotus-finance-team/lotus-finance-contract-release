module lotus_finance::lp_token {
    use std::option;

    use sui::coin;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    public struct LP_TOKEN has drop {}

    fun init(otw: LP_TOKEN, ctx: &mut TxContext) {
        let (treasury_cap, deny_cap, meta_data) = coin::create_regulated_currency(
            otw,
            6,
            b"Lotus LP Token",
            b"LFLP",
            b"LP token for Lotus Finance",
            option::none(),
            ctx,
        );

        let sender = ctx.sender();
        transfer::public_transfer(deny_cap, sender);
        transfer::public_transfer(treasury_cap, sender);
        transfer::public_freeze_object(meta_data);
    }

    #[test_only]
    public fun init_for_test(ctx: &mut TxContext): (coin::TreasuryCap<LP_TOKEN>, coin::DenyCap<LP_TOKEN>, coin::CoinMetadata<LP_TOKEN>) {
        let (treasury_cap, deny_cap, meta_data) = coin::create_regulated_currency(
            LP_TOKEN {},
            6,
            b"Lotus LP Token",
            b"LFLP",
            b"LP token for Lotus Finance",
            option::none(),
            ctx,
        );

        (treasury_cap, deny_cap, meta_data)
    }
}
