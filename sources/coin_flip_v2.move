module desui_labs::coin_flip_v2 {

    use std::vector;
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::bls12381::bls12381_min_pk_verify;
    use sui::hash::blake2b256;
    use sui::kiosk::{Self, Kiosk};
    use sui::event;
    use sui::dynamic_object_field as dof;

    // --------------- Constants ---------------

    const FEE_PRECISION: u128 = 1_000_000;
    const CHALLENGE_EPOCH_INTERVAL: u64 = 2;

    // --------------- Errors ---------------

    const EInvalidStakeAmount: u64 = 0;
    const EInvalidGuess: u64 = 1;
    const EInvalidBlsSig: u64 = 2;
    const EKioskItemNotFound: u64 = 3;
    const ECannotChallenge: u64 = 4;

    // --------------- Events ---------------

    struct NewGame<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        guess: u8,
        seed: vector<u8>,
        stake_amount: u64,
        partnership_type: Option<TypeName>,
    }

    struct Outcome<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        player_won: bool,
        pnl: u64,
        challenged: bool,
    }

    // --------------- Objects ---------------

    struct House<phantom T> has key {
        id: UID,
        pub_key: vector<u8>,
        fee_rate: u128,
        min_stake_amount: u64,
        max_stake_amount: u64,
        pool: Balance<T>,
        treasury: Balance<T>,
    }

    struct Game<phantom T> has key, store {
        id: UID,
        player: address,
        start_epoch: u64,
        stake: Balance<T>,
        guess: u8,
        seed: vector<u8>,
        fee_rate: u128,
    }

    struct Partnership<phantom P> has key {
        id: UID,
        fee_rate: u128,
    }

    struct AdminCap has key {
        id: UID,
    }

    // --------------- Constructor ---------------

    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // --------------- House Funtions ---------------
    
    public entry fun create_house<T>(
        _cap: &AdminCap,
        pub_key: vector<u8>,
        fee_rate: u128,
        min_stake_amount: u64,
        max_stake_amount: u64,
        init_fund: Coin<T>,
        ctx: &mut TxContext,
    ) {
        transfer::share_object(House<T> {
            id: object::new(ctx),
            pub_key,
            fee_rate,
            min_stake_amount,
            max_stake_amount,
            pool: coin::into_balance(init_fund),
            treasury: balance::zero(),
        });
    }

    public entry fun top_up<T>(
        house: &mut House<T>,
        coin: Coin<T>,
    ) {        
        let balance = coin::into_balance(coin);
        balance::join(&mut house.pool, balance);
    }

    public entry fun withdraw<T>(
        _: &AdminCap,
        house: &mut House<T>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let coin = coin::take(&mut house.pool, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    public entry fun claim<T>(
        _: &AdminCap,
        house: &mut House<T>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let fee_amount = balance::value(&house.treasury);
        let fee = coin::take(&mut house.treasury, fee_amount, ctx);
        transfer::public_transfer(fee, recipient);
    }

    public entry fun update_max_stake_amount<T>(
        _: &AdminCap,
        house: &mut House<T>,
        max_stake_amount: u64,
    ) {
        house.max_stake_amount = max_stake_amount;
    }

    public entry fun update_min_stake_amount<T>(
        _: &AdminCap,
        house: &mut House<T>,
        min_stake_amount: u64,
    ) {
        house.min_stake_amount = min_stake_amount;
    }

    public entry fun update_fee_rate<T>(
        _: &AdminCap,
        house: &mut House<T>,
        fee_rate: u128,
    ) {
        house.fee_rate = fee_rate;
    }

    // --------------- Partnership Funtions ---------------

    public entry fun create_partnership<P>(
        _: &AdminCap,
        fee_rate: u128,
        ctx: &mut TxContext,
    ) {
        transfer::share_object(Partnership<P> {
            id: object::new(ctx),
            fee_rate,
        });
    }

    public entry fun update_partnership_rate<P>(
        _: &AdminCap,
        partnership: &mut Partnership<P>,
        fee_rate: u128,
    ) {
        partnership.fee_rate = fee_rate;
    }

    // --------------- Game Funtions ---------------

    public entry fun start_game<T>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        ctx: &mut TxContext,
    ) {
        let fee_rate = house.fee_rate;
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, option::none(), ctx);
        dof::add(&mut house.id, game_id, game);
    }

    public entry fun start_game_with_parternship<T, P: key>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        partnership: &Partnership<P>,
        _proof: &P,
        ctx: &mut TxContext,
    ) {
        let fee_rate = min_u128(house.fee_rate, partnership.fee_rate);
        let partnership_type = option::some(type_name::get<P>());
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
    }

    public entry fun start_game_with_kiosk<T, P: key + store>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        partnership: &Partnership<P>,
        kiosk: &Kiosk,
        item: ID,
        ctx: &mut TxContext,
    ) {
        let fee_rate = min_u128(house.fee_rate, partnership.fee_rate);
        let partnership_type = option::some(type_name::get<P>());
        assert!(
            kiosk::has_item_with_type<P>(kiosk, item),
            EKioskItemNotFound,
        );
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
    }

    // --------------- Settle Funtions ---------------

    public entry fun settle<T>(
        house: &mut House<T>,
        game_id: address,
        bls_sig: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let game_id = object::id_from_address(game_id);
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch: _,
            stake,
            guess,
            seed,
            fee_rate,
        } = game;
        let msg_vec = object::uid_to_bytes(&id);
        vector::append(&mut msg_vec, seed);
        assert!(
            bls12381_min_pk_verify(
                &bls_sig, &house.pub_key, &msg_vec,
            ),
            EInvalidBlsSig
        );
        let stake_amount = balance::value(&stake);
        object::delete(id);

        let hashed_beacon = blake2b256(&bls_sig);
        let first_byte = *vector::borrow(&hashed_beacon, 0);
        let player_won: bool = (guess == first_byte % 2);

        let pnl: u64 = if(player_won) {
            let fee_amount = compute_fee_amount(stake_amount, fee_rate);
            let fee = balance::split(&mut stake, fee_amount);
            balance::join(&mut house.treasury, fee);
            let reward = balance::split(&mut house.pool, stake_amount);
            balance::join(&mut reward, stake);
            let reward_coin = coin::from_balance(reward, ctx);
            transfer::public_transfer(reward_coin, player);
            stake_amount - fee_amount
        } else {
            balance::join(&mut house.pool, stake);
            stake_amount
        };

        event::emit(Outcome<T> {
            game_id,
            player,
            player_won,
            pnl,
            challenged: false,
        });
    }

    public entry fun challenge<T>(
        house: &mut House<T>,
        game_id: address,
        ctx: &mut TxContext,
    ) {
        let game_id = object::id_from_address(game_id);
        let current_epoch = tx_context::epoch(ctx);
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch,
            stake,
            guess: _,
            seed: _,
            fee_rate: _,
        } = game;
        // Ensure that minimum epochs have passed before user can cancel
        assert!(start_epoch + CHALLENGE_EPOCH_INTERVAL <= current_epoch, ECannotChallenge);

        transfer::public_transfer(coin::from_balance(stake, ctx), player);
        
        object::delete(id);
        event::emit(Outcome<T> {
            game_id,
            player,
            player_won: true,
            pnl: 0,
            challenged: true,
        });
    }

    // --------------- House Accessors ---------------

    public fun house_pub_key<T>(house: &House<T>): vector<u8> {
        house.pub_key
    }

    public fun house_fee_rate<T>(house: &House<T>): u128 {
        house.fee_rate
    }

    public fun house_pool_balance<T>(house: &House<T>): u64 {
        balance::value(&house.pool)
    }

    public fun house_stake_range<T>(house: &House<T>): (u64, u64) {
        (house.min_stake_amount, house.max_stake_amount)
    }

    public fun is_unsettled<T>(house: &House<T>, game_id: ID): bool {
        dof::exists_with_type<ID, Game<T>>(&house.id, game_id)
    }

    // --------------- Game Accessors ---------------

    public fun borrow_game<T>(house: &House<T>, game_id: ID): &Game<T> {
        dof::borrow<ID, Game<T>>(&house.id, game_id)
    }

    public fun game_start_epoch<T>(game: &Game<T>): u64 {
        game.start_epoch
    }

    public fun game_guess<T>(game: &Game<T>): u8 {
        game.guess
    }

    public fun game_stake_amount<T>(game: &Game<T>): u64 {
        balance::value(&game.stake)
    }

    public fun game_fee_rate<T>(game: &Game<T>): u128 {
        game.fee_rate
    }

    public fun game_seed<T>(game: &Game<T>): vector<u8> {
        game.seed
    }

    // --------------- Private Funtions ---------------

    fun new_game<T>(
        house: &House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        fee_rate: u128,
        partnership_type: Option<TypeName>,
        ctx: &mut TxContext,
    ): (ID, Game<T>) {
        // Ensure that guess is either 0 or 1
        assert!(guess == 1 || guess == 0, EInvalidGuess);
        // Ensure the stake amount is valid
        let stake_amount = coin::value(&stake);
        assert!(
            stake_amount >= house.min_stake_amount &&
            stake_amount <= house.max_stake_amount,
            EInvalidStakeAmount
        );

        let id = object::new(ctx);
        let game_id = object::uid_to_inner(&id);
        let player = tx_context::sender(ctx);
        event::emit(NewGame<T> {
            game_id,
            player,
            guess,
            seed,
            stake_amount,
            partnership_type,
        });
        
        let game = Game<T> {
            id,
            player,
            start_epoch: tx_context::epoch(ctx),
            stake: coin::into_balance(stake),
            guess,
            seed,
            fee_rate,
        };
        (game_id, game)
    }

    fun compute_fee_amount(amount: u64, fee_rate: u128): u64 {
        (((amount as u128) * fee_rate / FEE_PRECISION) as u64)
    }
    
    fun min_u128(x: u128, y: u128): u128 {
        if (x <= y) { x } else { y }
    }

    // --------------- Test only ---------------

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    public fun start_game_for_testing<T>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        ctx: &mut TxContext
    ): ID {
        let fee_rate = house.fee_rate;
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, option::none(), ctx);
        dof::add(&mut house.id, game_id, game);
        game_id    
    }

    #[test_only]
    public fun settle_for_testing<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let game = dof::remove<ID, Game<T>>(&mut house.id, game_id);
        let Game {
            id,
            player,
            start_epoch: _,
            stake,
            guess,
            seed: _,
            fee_rate,
        } = game;
        // let msg_vec = object::uid_to_bytes(&id);
        // vector::append(&mut msg_vec, seed);
        // assert!(
        //     bls12381_min_pk_verify(
        //         &bls_sig, &pub_key, &msg_vec,
        //     ),
        //     EInvalidBlsSig
        // );
        let stake_amount = balance::value(&stake);
        object::delete(id);

        let hashed_beacon = blake2b256(&bls_sig);
        let first_byte = *vector::borrow(&hashed_beacon, 0);
        let player_won: bool = (guess == first_byte % 2);

        let pnl: u64 = if(player_won) {
            let fee_amount = compute_fee_amount(stake_amount, fee_rate);
            let fee = balance::split(&mut stake, fee_amount);
            balance::join(&mut house.treasury, fee);
            let reward = balance::split(&mut house.pool, stake_amount);
            balance::join(&mut reward, stake);
            let reward_coin = coin::from_balance(reward, ctx);
            transfer::public_transfer(reward_coin, player);
            stake_amount - fee_amount
        } else {
            balance::join(&mut house.pool, stake);
            stake_amount
        };

        event::emit(Outcome<T> {
            game_id,
            player,
            player_won,
            pnl,
            challenged: false,
        });
    }
}