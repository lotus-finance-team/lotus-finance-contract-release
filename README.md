# Lotus Finance Contract

This is contract repository for Lotus Finance.
Lotus Finance is a strategy trading protocol on Sui. Users can get access to market making and quantitative trading strategies through the protocol which were previously privileged by institutional investors.

# High level structure

![architecture](./docs/lotus-finance-architecture.svg)

![entity-diagram](./docs/entity-diagram.svg)

# External Deps
## Testnet
| Package           | original_package_id | latest_package_id |
|-------------------|----------------------|-------------------|
| DeepbookV3        |0xa706f5eebcfde58ee1b03d642f222c646fe09b8d2d7a59fbee0fdc73fa21eb33|0xcbf4748a965d469ea3a36cf0ccc5743b96c2d0ae6dee0762ed3eca65fac07f7e|
| Deep Token        |0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8|(Same as original)|
| Pyth              |0xabf837e98c26087cba0883c0a7a28326b1fa3c5e1e2c5abdb486f9e8f594c837|0xabf837e98c26087cba0883c0a7a28326b1fa3c5e1e2c5abdb486f9e8f594c837|
| Wormhole          |0xf47329f4344f3bf0f8e436e2f7b485466cff300f12a166563995d3888c296a94| (Same as original) |
| USDC              |NA|NA|
| TokenDistribution |         NA           |        NA         |

## Mainnet
| Package           | original_package_id | latest_package_id |
|-------------------|----------------------|-------------------|
| DeepbookV3        |0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809|(Same as original)|
| Deep Token        |0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270|(Same as original)|
| Pyth              |0x8d97f1cd6ac663735be08d1d2b6d02a159e711586461306ce60a2b7a6a565a9e|0x04e20ddf36af412a4096f9014f4a565af9e812db9a05cc40254846cf6ed0ad91|
| Wormhole          |0x5306f64e312b581766351c07af79c72fcb1cd25147157fdc2f8ad76de9a3fb6a|(Same as original)|
| USDC              |NA|NA|
| TokenDistribution |                      |                   |

*Addresses as of 24th Dec 2024*