address 0x1 {
module CDP2 {
    use 0x1::Coins;
    use 0x1::Dfinance;
    use 0x1::Math;
    use 0x1::Account;
    use 0x1::Signer;
    use 0x1::Event;

    const MAX_LTV: u64 = 6600;  // 66.00%
    const SOFT_MARGIN_CALL: u64 = 150;
    const HARD_MARGIN_CALL: u64 = 130;

    const ERR_INCORRECT_LTV: u64 = 1;
    const ERR_NO_ORACLE_PRICE: u64 = 2;
    const ERR_HARD_MC_HAS_NOT_OCCURRED: u64 = 3;

    resource struct Offer<Offered: copyable, Collateral: copyable> {
        available_amount: Dfinance::T<Offered>,
        // < 6700, 2 signs after comma
        ltv: u64,
        // 2 signs after comma
        interest_rate: u64,
    }

    resource struct Deal<Offered, Collateral> {
        collateral: Dfinance::T<Collateral>,
        lender: address,
        ltv: u64,
        soft_mc: u128,
        hard_mc: u128,
    }

    public fun has_deal<Offered: copyable, Collateral: copyable>(borrower: address): bool {
        exists<Deal<Offered, Collateral>>(borrower)
    }

    public fun has_offer<Offered: copyable, Collateral: copyable>(lender: address): bool {
        exists<Offer<Offered, Collateral>>(lender)
    }

    public fun create_offer<Offered: copyable, Collateral: copyable>(
        account: &signer,
        available_amount: Dfinance::T<Offered>,
        ltv: u64,
        interest_rate: u64
    ) {
        assert(ltv <= MAX_LTV, ERR_INCORRECT_LTV);
        assert(Coins::has_price<Offered, Collateral>(), ERR_NO_ORACLE_PRICE);

        let amount_num = Dfinance::value(&available_amount);
        let offer = Offer<Offered, Collateral> { available_amount, ltv, interest_rate };
        move_to(account, offer);

        Event::emit(
            account,
            OfferCreatedEvent<Offered, Collateral> {
                available_amount: amount_num,
                ltv,
                interest_rate,
                lender: Signer::address_of(account),
            }
        );
    }

    public fun deposit_amount_to_offer<Offered: copyable, Collateral: copyable>(
        account: &signer,
        lender: address,
        amount: Dfinance::T<Offered>
    ) acquires Offer {
        let offer = borrow_global_mut<Offer<Offered, Collateral>>(lender);
        let amount_deposited_num = Dfinance::value(&amount);
        Dfinance::deposit<Offered>(&mut offer.available_amount, amount);

        Event::emit(
            account,
            OfferDepositedEvent<Offered, Collateral> {
                amount: amount_deposited_num,
                lender,
            }
        );
    }

    public fun make_deal<Offered: copyable, Collateral: copyable>(
        account: &signer,
        lender: address,
        collateral: Dfinance::T<Collateral>,
        ltv: u64
    ): Dfinance::T<Offered> acquires Offer {
        assert(
            ltv <= get_offer_ltv<Offered, Collateral>(lender),
            ERR_INCORRECT_LTV
        );

        let collateral_value_u128 = Dfinance::value<Collateral>(&collateral);
        let offered_amount = compute_collateral_value<Offered, Collateral>(collateral_value_u128, ltv);

        let offered_decimals = Dfinance::decimals<Offered>();
        let offered = withdraw_amount_from_offer<Offered, Collateral>(
            account,
            lender,
            Math::as_scaled_u128(copy offered_amount, offered_decimals)
        );

        let (soft_mc, hard_mc) = compute_margin_calls(offered_amount, offered_decimals);

        let borrower = Signer::address_of(account);
        move_to(
            account,
            Deal<Offered, Collateral> {
                collateral,
                lender,
                ltv,
                soft_mc,
                hard_mc
            });
        Event::emit(
            account,
            DealCreated<Offered, Collateral> {
                lender,
                borrower,
                offered: Dfinance::value(&offered),
                collateral: collateral_value_u128,
                ltv,
                soft_mc,
                hard_mc,
            });
        offered
    }

    public fun release_deal_and_deposit_collateral<Offered: copyable, Collateral: copyable>(
        account: &signer,
        borrower: address,
    ) acquires Deal {
        let Deal {
            collateral,
            lender,
            ltv,
            soft_mc,
            hard_mc
        } = move_from<Deal<Offered, Collateral>>(borrower);

        let collateral_value_stored = Dfinance::value(&collateral);
        let collateral_value_unscaled = compute_collateral_value<Offered, Collateral>(
            collateral_value_stored,
            10000
        );
        // same dimension as margin calls
        let collateral_value = Math::as_scaled_u128(collateral_value_unscaled, Dfinance::decimals<Offered>());
        assert(
            collateral_value <= hard_mc,
            ERR_HARD_MC_HAS_NOT_OCCURRED
        );

        // deposit token
        Account::deposit<Collateral>(account, lender, collateral);

        Event::emit(
            account,
            DealClosed<Offered, Collateral> {
                lender,
                borrower,
                collateral: collateral_value_stored,
                collateral_in_offered: collateral_value,
                ltv,
                soft_mc,
                hard_mc,
            })
    }

    fun get_offer_ltv<Offered: copyable, Collateral: copyable>(lender: address): u64 acquires Offer {
        let offer = borrow_global<Offer<Offered, Collateral>>(lender);
        offer.ltv
    }

    fun withdraw_amount_from_offer<Offered: copyable, Collateral: copyable>(
        account: &signer,
        lender: address,
        amount: u128
    ): Dfinance::T<Offered> acquires Offer {
        let offer = borrow_global_mut<Offer<Offered, Collateral>>(lender);
        let borrowed = Dfinance::withdraw<Offered>(&mut offer.available_amount, amount);

        Event::emit(
            account,
            OfferDepositBorrowedEvent<Offered, Collateral> {
                amount,
                lender
            }
        );
        borrowed
    }

    fun compute_margin_calls(offered_amount: Math::Number, offered_scale: u8): (u128, u128) {
        let soft_mc_multiplier = Math::create_from_decimal(SOFT_MARGIN_CALL, 2);
        let soft_mc = Math::mul(copy offered_amount, soft_mc_multiplier);

        let hard_mc_multiplier = Math::create_from_decimal(HARD_MARGIN_CALL, 2);
        let hard_mc = Math::mul(copy offered_amount, hard_mc_multiplier);

        (Math::as_scaled_u128(soft_mc, offered_scale), Math::as_scaled_u128(hard_mc, offered_scale))
    }

    fun compute_collateral_value<Offered: copyable, Collateral: copyable>(collateral: u128, ltv: u64): Math::Number {
        let exchange_rate_u128 = Coins::get_price<Offered, Collateral>();
        let exchange_rate = Math::create_from_u128_decimal(exchange_rate_u128, 8);
        let ltv_num = Math::create_from_decimal(ltv, 4);

        let collateral_decimals = Dfinance::decimals<Collateral>();
        let collateral_value = Math::create_from_u128_decimal(collateral, collateral_decimals);

        let offered_amount = Math::mul(
            Math::mul(
                exchange_rate,
                collateral_value
            ),
            ltv_num
        );
        offered_amount
    }

    struct OfferCreatedEvent<Offered: copyable, Collateral: copyable> {
        available_amount: u128,
        // < 6700
        ltv: u64,
        interest_rate: u64,
        lender: address,
    }

    struct OfferDepositedEvent<Offered: copyable, Collateral: copyable> {
        amount: u128,
        lender: address,
    }

    struct OfferDepositBorrowedEvent<Offered: copyable, Collateral: copyable> {
        amount: u128,
        lender: address,
    }

    struct DealCreated<Offered: copyable, Collateral: copyable> {
        lender: address,
        borrower: address,
        offered: u128,
        collateral: u128,
        ltv: u64,
        soft_mc: u128,
        hard_mc: u128,
    }

    struct DealClosed<Offered: copyable, Collateral: copyable> {
        lender: address,
        borrower: address,
        collateral: u128,
        collateral_in_offered: u128,
        ltv: u64,
        soft_mc: u128,
        hard_mc: u128,
    }
}
}


