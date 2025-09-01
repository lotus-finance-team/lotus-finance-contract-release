# Test Case for pooling

1. User deposit
1.1.
    - Time: 1000
    - Tokens
        - SUI: 110
        - USDC: 130
        - DEEP
    - Price
        - SUI: 4
        - USDC: 1
        - DEEP: 0.1
    - Vault
        - User Cost
            - [user]: 570
        - User Shares
            - [user]: 570
    - Farm
        - T0: 1200
        - Rate: 100
1.2.
    - Time: 1300
    - Tokens
    - Price
    - Vault Assets
        - SUI: 110
        - USDC: 130
        - DEEP: 0
    - Assertion
        - User Incentive:
            - (1300 - 1200) * 100
1.3.
    - Stake: deposit 100_000_000_000 DEEP and stake.
    - Claim rebate
2. Alice Ops
2.1.
    - Time: 1300
    - Operation: Alice Deposit
    - Tokens
        - SUI: 100
        - USDC: 5_200
        - DEEP
    - Price
        - SUI: 3
        - USDC: 1
        - DEEP: 0.1
    - Vault Assets
        - SUI: 210
        - USDC: 5_330
        - DEEP: 0
    - Vault
        - User Cost
            - [user]: 570
            - [alice]: 5500
        - User Shares
            - [user]: 570
            - [alice]: total_shares_before_alice / total_value_before_alice * alice_cost
                - 570 / (110 * 3 + 130 * 1) * 5500 = 6815.217391304348
    - Assertion
        - vault_usd_value
        - user_cost(Alice)
        - user_cost(user)
        - alice_shares
2.2.
    - Time: 1400
    - Operation: Alice pooling_redeem_incentive
    - Assertion
        - Alice incentive
            - 100 * 100 * 5500 / 5960
2.3.
    - Time: 1400
    - Operation: Alice Withdraw
    - Price
        - SUI: 4
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - Withdraw amount
            - Without Fee:
                - USDC: Alice share / total share * (5200 + 130)
                    - 6815.217391304348 / (6815.217391304348 + 570) * (5200 + 130) = 4918.624161073826
                - SUI: Alice share / total share * (100 + 110)
                    - 6815.217391304348 / (6815.217391304348 + 570) * (100 + 110) = 193.79194630872485
            - Performance Fee
                - Alice holding value
                    - total vault value * alice share / total share
                        - (210 * 4 + 5_330 * 1) * 6815.217391304348 / (6815.217391304348 + 570) = 5693.791946308725
                - Performance ratio
                    - 0.1 * (5693.791946308725 - 5500) / 5693.791946308725 = 0.003403565640194486 // Cut 8 digits
            - Withdraw amount
                - SUI: 193.79194630872485 * (1 - 0.00340356) = 193.13236379194632
                - USDC: 4918.624161073826 * (1 - 0.00340356) = 4901.883328624162
        - Cost
            - user_cost(Alice)
                - 100 * 4 + 5_200 * 1 = 5500
        - Current value
            - 100 * 4 + 5_200 * 1 = 5600
        - Performance fee ratio
            - 0.1 * (5600 - 5500) / 5600
    - Vault (after)
        - User Cost
            - [user]: 570
            - [alice]: None
        - User Shares
            - [user]: 570
            - [alice]: None
        - Vault Assets
            - SUI: 210 - 193.79194630872485 = 16.208053691275154
            - USDC: 5_330 - 4918.624161073826 = 411.375838926174
3. Alice Ops
3.1.
    - Time: 1500
    - Operation: Alice Deposit
    - Tokens
        - SUI: 100
        - USDC: 2_200
        - DEEP
    - Price
        - SUI: 4
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - vault_usd_value_before
            - 16.208053691 * 4 + 411.375838 * 1 = 476.208052764
        - user_cost(Alice)
            - 100 * 4 + 2_200 * 1 = 2600
        - Alice share
            - alice_cost * total_shares_before_alice / vault_usd_value_before
                - 2600 * 570 / 476.208052764 = 3112.085130434474
        - vault_usd_value
        - farm_usd_value
    - Vault (after)
        - User Cost
            - [user]: 570
            - [alice]: 2600
        - User Shares
            - [user]: 570
            - [alice]: 3112.085130434474
        - Vault Assets
            - SUI: 16.208053691275154 + 100 = 116.20805369127515
            - USDC: 411.375838926174 + 2_200 = 2611.375838926174
3.2.
    - Time: 1600
    - Operation: Alice Deposit Again
    - Tokens
        - SUI: 100
        - USDC: 2_100
        - DEEP
    - Price
        - SUI: 5
        - USDC: 1
        - DEEP: 0.1
    - Vault Assets (before)
        - SUI: 16.208053691 + 100
        - USDC: 411.375838 + 2_200
        - DEEP: 0
    - Assertion
        - vault_usd_value_before
            - 116.208053691 * 5 + 2_611.375838 * 1 = 3192.416106455
        - user_cost(Alice)
            - 2600 + 100 * 5 + 2_100 * 1 = 5200
        - Alice share
            - alice_cost * total_shares_before_alice / vault_usd_value_before + original_alice_shares
                - 2600 * (3112.085130434474 + 570) / 3192.416106455 + 3112.085130434474 = 6110.886358060275
    - Vault (after)
        - User Cost
            - [user]: 570
            - [alice]: 5200
        - User Shares
            - [user]: 570
            - [alice]: 6110.886358060275
        - Vault Assets
            - SUI: 116.208053691 + 100 = 216.208053691
            - USDC: 2_611.375838926174 + 2_100 = 4_711.375838926174
            - DEEP: 0

4. Charlie Ops
4.1.
    - Time: 1700
    - Operation: Charlie Deposit
    - Tokens
        - SUI: 100
        - USDC: 2_300
        - DEEP
    - Price
        - SUI: 6
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - vault_usd_value_before
            - 216.208053691 * 6 + 4_711.375838926174 * 1 = 6008.624161072174
        - user_cost(Charlie)
            - 100 * 6 + 2_300 * 1 = 2900
        - Charlie share
            - charlie_cost * total_shares_before_charlie / vault_usd_value_before
                - 2900 * (6110.886358060275 + 570) / 6008.624161072174 = 3224.4603621401434
    - Vault (after)
        - User Cost
            - [user]: 570
            - [alice]: 5200
            - [charlie]: 2900
        - User Share
            - [user]: 570
            - [alice]: 6110.886358060275
            - [charlie]: 3224.4603621401434
        - Vault Asset
            - SUI: 216.208053691 + 100 = 316.208053691
            - USDC: 4_711.375838926174 + 2300 = 7_011.375838926174
5. Alice Ops
5.1.
    - Time: 1800
    - Operation: Alice pooling_redeem_incentive
    - Assertion
        - Alice incentive
5.2.
    - Time: 1800
    - Operation: Alice Withdraw
    - Price
        - SUI: 7
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - Alice withdraw amount
            - Without Fee:
                - SUI: alice share / total share * (100 + 216.208053691)
                    - 6110.886358060275 / (6110.886358060275 + 570 + 3224.4603621401434) * (100 + 216.208053691) = 195.077621833113
                - USDC: alice share / total share * (2_300 + 4_711.375838926174)
                    - 6110.886358060275 / (6110.886358060275 + 570 + 3224.4603621401434) * (2_300 + 4_711.375838926174) = 4325.514510052452
            - Performance Fee
                - Alice holding value
                    - total vault value * alice share / total share
                        - (316.208053691 * 7 + 7_011.375838926174 * 1) * 6110.886358060275 / (6110.886358060275 + 570 + 3224.4603621401434) = 5691.057862884242
                - Performance ratio
                    - 0.1 * (5691.057862884242 - 5200) / 5691.057862884242 = 0.008628586718241044 // Cut 8 digits
            - Withdraw amount
                - SUI: 195.077621833113 * (1 - 0.00862858) = 193.39437896691624
                - USDC: 4325.514510052452 * (1 - 0.00862858) = 4288.191462061304

6. User Close Vault
6.1.
    - Time: 1900
    - Operation: User withdraw
    - Price
        - SUI: 8
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - user_cost(user)
        - user incentive
        - user withdraw SUI amount
        - user withdraw USDC amount
    - Unstake DEEP
6.2
    - Time: 2000
    - Operation: Admin withdraw for Charlie
    - Price
        - SUI: 8
        - USDC: 1
        - DEEP: 0.1
    - Assertion
        - Charlie withdraw SUI amount
        - Charlie withdraw USDC amount
6.3
    - Time: 2200
    - Operation: close vault


# Test Case for pooling numeric #1
1. User deposit 100_000 SUI and 1_000_000 USDC
2. Alice deposit 100 SUI and 100 USDC and withdraw, iterate for 10 times

# Test Case for pooling numeric #2
1. User deposit 100_000 SUI and 1_000_000 USDC, SUI price 4 USDC.
2. Alice deposit 100 USDC and withdraw, iterate for 100 times, price change to 8 when deposit while withdraw at 2

# Test Case for fees
1. Performance fee 0.13, Strategy fee 0.17
2. User deposit 100_000 SUI and 1_000_000 USDC, SUI price 4 USDC.
3. Alice deposit 200_000 SUI and 2_000_000 USDC, SUI price 4 USDC.
4. Update price to SUI 8 USDC
5. User withdraw, collect performance fee should be:
    - Cost: 1_400_000. Withdraw value: 1_800_000
    - Performance fee:
        - Ratio: 0.13 * (1_800_000 - 1_400_000) / 1_800_000 = 0.028888888888888888
        - Amount: 0.028888888888888888 * 100_000 SUI = 2888.888888888889 SUI, 0.028888888888888888 * 1_000_000 USDC = 28888.88888888889 USDC
    - Strategy fee:
        - Ratio: 0.17 * (1_800_000 - 1_400_000) / 1_800_000 = 0.03777777777777778
    - Withdrawal amount before early withdrawal fee:
        - SUI: 100_000 * (1 - 0.028888888888888888 - 0.03777777777777778) = 93333.333333333333 SUI
        - USDC: 1_000_000 * (1 - 0.028888888888888888 - 0.03777777777777778) = 93333.33333333333 USDC
    - Early withdrawal fee:
        93333.333333333333 * 0.008 = 746.6666666666667 SUI, 93333.33333333333 * 0.008 = 746.6666666666667 USDC
    - Actual withdrawal amount:
        - SUI: 93333.333333333333 - 746.6666666666667 = 92586.66666666667 SUI
        - USDC: 93333.33333333333 - 746.6666666666667 = 92586.66666666667 USDC
6. Alice withdraw, collect performance fee should be:
    - Performance fee:
        - 5_777 SUI, 57_777 USDC
    - Strategy fee:
        7_555 SUI, 75_555 USDC
