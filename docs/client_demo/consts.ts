import { CoinMap } from "@mysten/deepbook-v3";

export const DEEPBOOK_PACKAGE_ID    = "0xcbf4748a965d469ea3a36cf0ccc5743b96c2d0ae6dee0762ed3eca65fac07f7e";

export const LOTUS_PACKAGE_ID         = "0xe8c606b96e6b84e7f2c4c25924cbfc6a30114ef3662f8daf5f9a0087c441ecde";
export const ORACLE_AGGREGATOR        = "0x7ee0c96a104a32af8fc1be1303be81f0ea174b3dc2f8a034c85f96b311ab3e3b";
export const ORACLE_AGGREGATOR_CAP    = "0xb36e0d11b949f80c5d2804e15a91691cc07ed84ccfa5a52444b387113a884ce3";
export const LOTUS_CONFIG             = "0x791d9b90726ee02bb88666d986f6ce7a9f7e38e620c9bf21b8873a4e87c60a75";
export const LOTUS_CONFIG_CAP         = "0xfc8d5659fb7d88c1457b9cf8df3fae4133ba4e377744b351a91624b9c3935117";

export const LF_LP_TOKEN            = LOTUS_PACKAGE_ID;

export const WORMHOLE_STATE_ID      = "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790";
export const PYTH_STATE_ID          = "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c";

export const MAX_TIMESTAMP = 1844674407370955161;

export const CZERO_VALUE = 1 << 0;
export const CPYTH_PRICE = 1 << 10;

export const COINS = {
    DEEP: {
        address: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8`,
        type: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`,
        scalar: 1_000_000,
    },
    SUI: {
        address: `0x0000000000000000000000000000000000000000000000000000000000000002`,
        type: `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`,
        scalar: 1_000_000_000,
    },
    DBUSDC: {
        address: `0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7`,
        type: `0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDC::DBUSDC`,
        scalar: 1_000_000,
    },
    USDC: {
        address: `0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29`,
        type: `0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC`,
        scalar: 1_000_000,
    }
}

export const DB_POOLS = {
    DEEP_SUI: {
        address: `0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f`,
    }
}

export const PYTH_FEEDS = {
    "USDC/USD": {
        address: `0x41f3625971ca2ed2263e78573fe5ce23e13d2558ed3f2e47ab0f84fb9e7ae722`,
    },
    "SUI/USD": {
        address: `0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266`,
    },
    "DEEP/USD": {
        // address: `0xe18bf5fa857d5ca8af1f6a458b26e853ecdc78fc2f3dc17f4821374ad94d8327`,
        address: `0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266`
    },
}

export const LP_TOKEN_TYPE = `${LF_LP_TOKEN}::lp_token::LP_TOKEN`;
