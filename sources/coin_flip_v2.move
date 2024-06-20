module desui_labs::coin_flip_v2 {

    use std::type_name::{Self, TypeName};
    use sui::{
        event,
        package,
        kiosk::Kiosk,
        hash::blake2b256,
        coin::{Self, Coin},
        balance::{Self, Balance},
        dynamic_object_field as dof,
        bls12381::bls12381_min_pk_verify
    };

    // --------------- Constants ---------------

    const FEE_PRECISION: u128 = 1_000_000;
    const MAX_FEE_RATE: u128 = 10_000;
    const CHALLENGE_EPOCH_INTERVAL: u64 = 7;

    // --------------- Errors ---------------

    const EInvalidStakeAmount: u64 = 0;
    const EInvalidGuess: u64 = 1;
    const EInvalidBlsSig: u64 = 2;
    const EKioskItemNotFound: u64 = 3;
    const ECannotChallenge: u64 = 4;
    const EInvalidFeeRate: u64 = 5;
    const EPoolNotEnough: u64 = 6;
    const EGameNotExists: u64 = 7;
    const EBatchSettleInvalidInputs: u64 = 8;

    // --------------- Events ---------------

    public struct NewGame<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        guess: u8,
        seed: vector<u8>,
        stake_amount: u64,
        partnership_type: Option<TypeName>,
    }

    public struct NewAutobetGame<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        guesses: vector<u8>,
        seeds: vector<vector<u8>>,
        stake_amount: u64,
        partnership_type: Option<TypeName>,
    }

    public struct Outcome<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        player_won: bool,
        pnl: u64,
        challenged: bool,
    }

    public struct AutobetOutcome<phantom T> has copy, drop {
        game_id: ID,
        player: address,
        player_wins: vector<bool>,
        pnl: u64,
        challenged: bool,
    }

    public struct FeeCollected<phantom T> has copy, drop {
        amount: u64,
    }

    // --------------- Objects ---------------

    public struct House<phantom T> has key {
        id: UID,
        pub_key: vector<u8>,
        fee_rate: u128,
        min_stake_amount: u64,
        max_stake_amount: u64,
        pool: Balance<T>,
        treasury: Balance<T>,
    }

    public struct AutobetGame<phantom T> has key, store {
        id: UID,
        player: address,
        start_epoch: u64,
        stake: Balance<T>,
        guesses: vector<u8>,
        seeds: vector<vector<u8>>,
        fee_rate: u128,        
    }

    public struct Game<phantom T> has key, store {
        id: UID,
        player: address,
        start_epoch: u64,
        stake: Balance<T>,
        guess: u8,
        seed: vector<u8>,
        fee_rate: u128,
    }

    public struct Partnership<phantom P> has key {
        id: UID,
        fee_rate: u128,
    }

    public struct AdminCap has key {
        id: UID,
    }

    // --------------- Witness ---------------

    public struct COIN_FLIP_V2 has drop {}

    // --------------- Constructor ---------------

    fun init(otw: COIN_FLIP_V2, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);
        transfer::public_transfer(publisher, ctx.sender());
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());
    }

    // --------------- House Funtions ---------------
    
    public entry fun create_house<T>(
        _: &AdminCap,
        pub_key: vector<u8>,
        fee_rate: u128,
        min_stake_amount: u64,
        max_stake_amount: u64,
        init_fund: Coin<T>,
        ctx: &mut TxContext,
    ) {
        assert!(fee_rate <= MAX_FEE_RATE, EInvalidFeeRate);
        transfer::share_object(House<T> {
            id: object::new(ctx),
            pub_key,
            fee_rate,
            min_stake_amount,
            max_stake_amount,
            pool: init_fund.into_balance(),
            treasury: balance::zero(),
        });
    }

    public entry fun top_up<T>(
        _: &AdminCap,
        house: &mut House<T>,
        coin: Coin<T>,
    ) {        
        let balance = coin.into_balance();
        house.pool.join(balance);
    }

    public entry fun withdraw<T>(
        _: &AdminCap,
        house: &mut House<T>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(amount <= house.pool.value(), EPoolNotEnough);
        let coin = coin::take(&mut house.pool, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    public entry fun claim<T>(
        _: &AdminCap,
        house: &mut House<T>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let treaury_balance = house.treasury.value();
        let fee = coin::take(
            &mut house.treasury,
            treaury_balance,
            ctx,
        );
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
        assert!(fee_rate <= MAX_FEE_RATE, EInvalidFeeRate);
        house.fee_rate = fee_rate;
    }

    public entry fun copy_admin_cap_to(
        _: &AdminCap,
        to: address,
        ctx: &mut TxContext,
    ) {
        let admin_cap = AdminCap { id: object::new(ctx)};
        transfer::transfer(admin_cap, to);
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

    public entry fun update_partnership_fee_rate<P>(
        _: &AdminCap,
        partnership: &mut Partnership<P>,
        fee_rate: u128,
    ) {
        assert!(fee_rate < FEE_PRECISION, EInvalidFeeRate);
        partnership.fee_rate = fee_rate;
    }

    // --------------- Game Funtions ---------------

    public entry fun start_game<T>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        ctx: &mut TxContext,
    ): ID {
        let fee_rate = house.fee_rate;
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, option::none(), ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
    }

    public entry fun start_game_with_parternship<T, P: key>(
        house: &mut House<T>,
        guess: u8,
        seed: vector<u8>,
        stake: Coin<T>,
        partnership: &Partnership<P>,
        _proof: &P,
        ctx: &mut TxContext,
    ): ID {
        let fee_rate = min_u128(
            house_fee_rate(house),
            partnership_fee_rate(partnership)
        );
        let partnership_type = option::some(type_name::get<P>());
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
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
    ): ID {
        let fee_rate = min_u128(
            house_fee_rate(house),
            partnership_fee_rate(partnership)
        );
        let partnership_type = option::some(type_name::get<P>());
        assert!(kiosk.has_item_with_type<P>(item), EKioskItemNotFound);
        let (game_id, game) = new_game(house, guess, seed, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
    }

    // --------------- Autobet Game Funtions ---------------

    public entry fun start_autobet_game<T>(
        house: &mut House<T>,
        seeds: vector<vector<u8>>,
        stake: Coin<T>,
        ctx: &mut TxContext,
    ): ID {
        let fee_rate = house.fee_rate;
        let (game_id, game) = new_autobet_game(house, seeds, stake, fee_rate, option::none(), ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
    }

    public entry fun start_autobet_game_with_parternship<T, P: key>(
        house: &mut House<T>,
        seeds: vector<vector<u8>>,
        stake: Coin<T>,
        partnership: &Partnership<P>,
        _proof: &P,
        ctx: &mut TxContext,
    ): ID {
        let fee_rate = min_u128(
            house_fee_rate(house),
            partnership_fee_rate(partnership)
        );
        let partnership_type = option::some(type_name::get<P>());
        let (game_id, game) = new_autobet_game(house, seeds, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
    }

    public entry fun start_autobet_game_with_kiosk<T, P: key + store>(
        house: &mut House<T>,
        seeds: vector<vector<u8>>,
        stake: Coin<T>,
        partnership: &Partnership<P>,
        kiosk: &Kiosk,
        item: ID,
        ctx: &mut TxContext,
    ): ID {
        let fee_rate = min_u128(
            house_fee_rate(house),
            partnership_fee_rate(partnership)
        );
        let partnership_type = option::some(type_name::get<P>());
        assert!(kiosk.has_item_with_type<P>(item), EKioskItemNotFound);
        let (game_id, game) = new_autobet_game(house, seeds, stake, fee_rate, partnership_type, ctx);
        dof::add(&mut house.id, game_id, game);
        game_id
    }

    // --------------- Settle Funtions ---------------

    public entry fun settle<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
        ctx: &mut TxContext,
    ): bool {
        assert!(game_exists(house, game_id), EGameNotExists);
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
        let msg_vec = id.uid_to_bytes();
        
        let player_won = compute_win(house.pub_key, msg_vec, seed, bls_sig, guess);
        id.delete();

        let pnl = settle_internal(house, player, player_won, stake, fee_rate, ctx);

        event::emit(Outcome<T> {
            game_id,
            player,
            player_won,
            pnl,
            challenged: false,
        });
        player_won
    }

    public entry fun batch_settle<T>(
        house: &mut House<T>,
        mut game_ids: vector<ID>,
        mut bls_sigs: vector<vector<u8>>,
        ctx: &mut TxContext,
    ) {
        assert!(
            game_ids.length() == bls_sigs.length(),
            EBatchSettleInvalidInputs,
        );
        while(!game_ids.is_empty()) {
            let game_id = game_ids.pop_back();
            let bls_sig = bls_sigs.pop_back();
            if (game_exists(house, game_id)) {
                settle(house, game_id, bls_sig, ctx);
            };
        };
    }

    public entry fun challenge<T>(
        house: &mut House<T>,
        game_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(game_exists(house, game_id), EGameNotExists);
        let current_epoch = ctx.epoch();
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
        assert!(current_epoch > start_epoch + CHALLENGE_EPOCH_INTERVAL, ECannotChallenge);
        let original_stake_amount = stake.value() / 2;
        transfer::public_transfer(coin::from_balance(stake, ctx), player);
        
        id.delete();
        event::emit(Outcome<T> {
            game_id,
            player,
            player_won: true,
            pnl: original_stake_amount,
            challenged: true,
        });
    }

    // --------------- Settle Autobet Funtions ---------------

    public entry fun settle_autobet<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
        ctx: &mut TxContext,
    ): vector<bool> {
        assert!(autobet_game_exists(house, game_id), EGameNotExists);
        let game = dof::remove<ID, AutobetGame<T>>(&mut house.id, game_id);
        let AutobetGame {
            id,
            player,
            start_epoch: _,
            stake,
            guesses,
            seeds,
            fee_rate,
        } = game;

        let mut player_wins = vector[];
        let num_of_bets = guesses.length();
        let mut i = 0;
        let msg_vec = id.uid_to_bytes();

        while (num_of_bets > i) {
            let player_won = compute_win(house.pub_key, msg_vec, seeds[i], bls_sig, guesses[i]);

            player_wins.push_back(player_won);

            i = i + 1;
        };

        id.delete();

        let pnl = settle_autobet_internal(house, player, player_wins, stake, fee_rate, ctx);

        event::emit(AutobetOutcome<T> {
            game_id,
            player,
            player_wins,
            pnl,
            challenged: false,
        });

        player_wins
    }

    public entry fun challenge_autobet<T>(
        house: &mut House<T>,
        game_id: ID,
        ctx: &mut TxContext,
    ) {
        assert!(autobet_game_exists(house, game_id), EGameNotExists);
        let current_epoch = ctx.epoch();
        let game = dof::remove<ID, AutobetGame<T>>(&mut house.id, game_id);
        let AutobetGame {
            id,
            player,
            start_epoch,
            stake,
            guesses: _,
            seeds: _,
            fee_rate: _,
        } = game;
        // Ensure that minimum epochs have passed before user can cancel
        assert!(current_epoch > start_epoch + CHALLENGE_EPOCH_INTERVAL, ECannotChallenge);
        let original_stake_amount = stake.value() / 2;
        transfer::public_transfer(coin::from_balance(stake, ctx), player);
        
        id.delete();
        event::emit(AutobetOutcome<T> {
            game_id,
            player,
            player_wins: vector[],
            pnl: original_stake_amount,
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
        house.pool.value()
    }

    public fun house_treasury_balance<T>(house: &House<T>): u64 {
        house.treasury.value()
    }

    public fun house_stake_range<T>(house: &House<T>): (u64, u64) {
        (house.min_stake_amount, house.max_stake_amount)
    }

    public fun game_exists<T>(house: &House<T>, game_id: ID): bool {
        dof::exists_with_type<ID, Game<T>>(&house.id, game_id)
    }

    public fun autobet_game_exists<T>(house: &House<T>, game_id: ID): bool {
        dof::exists_with_type<ID, AutobetGame<T>>(&house.id, game_id)
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
        game.stake.value()
    }

    public fun game_fee_rate<T>(game: &Game<T>): u128 {
        game.fee_rate
    }

    public fun game_seed<T>(game: &Game<T>): vector<u8> {
        game.seed
    }

    // --------------- Autobet Game Accessors ---------------

    public fun borrow_autobet_game<T>(house: &House<T>, game_id: ID): &AutobetGame<T> {
        dof::borrow<ID, AutobetGame<T>>(&house.id, game_id)
    }

    public fun autobet_game_start_epoch<T>(game: &AutobetGame<T>): u64 {
        game.start_epoch
    }

    public fun autobet_game_guesses<T>(game: &AutobetGame<T>): vector<u8> {
        game.guesses
    }

    public fun autobet_game_stake_amount<T>(game: &AutobetGame<T>): u64 {
        game.stake.value()
    }

    public fun autobet_game_fee_rate<T>(game: &AutobetGame<T>): u128 {
        game.fee_rate
    }

    public fun autobet_game_seeds<T>(game: &AutobetGame<T>): vector<vector<u8>> {
        game.seeds
    }

    // --------------- Partnership Accessors ---------------

    public fun partnership_fee_rate<P>(partnership: &Partnership<P>): u128 {
        partnership.fee_rate
    }

    // --------------- Helper Funtions ---------------

    fun new_game<T>(
        house: &mut House<T>,
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
        let mut stake = stake.into_balance();
        // house place the stake
        assert!(house.pool.value() >= stake_amount, EPoolNotEnough);
        let house_stake = house.pool.split(stake_amount);
        stake.join(house_stake);

        let id = object::new(ctx);
        let game_id = id.uid_to_inner();
        let player = ctx.sender();
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
            start_epoch: ctx.epoch(),
            stake,
            guess,
            seed,
            fee_rate,
        };
        (game_id, game)
    }

    fun new_autobet_game<T>(
        house: &mut House<T>,
        seeds: vector<vector<u8>>,
        stake: Coin<T>,
        fee_rate: u128,
        partnership_type: Option<TypeName>,
        ctx: &mut TxContext,
    ): (ID, AutobetGame<T>) {
        let num_of_bets = seeds.length();

        // Ensure the stake amount is valid
        let stake_amount = coin::value(&stake);
        let stake_per_bet = stake_amount / num_of_bets;

        assert!(
            stake_per_bet >= house.min_stake_amount &&
            stake_per_bet <= house.max_stake_amount,
            EInvalidStakeAmount
        );
        let mut stake = stake.into_balance();
        // house place the stake
        assert!(house.pool.value() >= stake_amount, EPoolNotEnough);
        let house_stake = house.pool.split(stake_amount);
        stake.join(house_stake);

        let id = object::new(ctx);
        let game_id = id.uid_to_inner();
        let player = ctx.sender();

        let mut guesses = vector[];
        let mut i = 0;

        while (num_of_bets > i) {
            guesses.push_back(((i % 2) as u8));
            i = i + 1;
        };
        
        event::emit(NewAutobetGame<T> {
            game_id,
            player,
            guesses,
            seeds,
            stake_amount,
            partnership_type,
        });
        
        let game = AutobetGame<T> {
            id,
            player,
            start_epoch: ctx.epoch(),
            stake,
            guesses,
            seeds,
            fee_rate,
        };

        (game_id, game)
    }

    fun settle_internal<T>(
        house: &mut House<T>,
        player: address,
        player_won: bool,
        mut stake: Balance<T>,
        fee_rate: u128,
        ctx: &mut TxContext,
    ): u64 {
        let stake_amount = stake.value();
        let original_stake_amount = stake_amount / 2;
        if(player_won) {
            let fee_amount = compute_fee_amount(stake_amount, fee_rate);
            let fee = stake.split(fee_amount);
            event::emit(FeeCollected<T> {
                amount: fee_amount,
            });
            house.treasury.join(fee);
            let reward = coin::from_balance(stake, ctx);
            transfer::public_transfer(reward, player);
            original_stake_amount - fee_amount
        } else {
            house.pool.join(stake);
            original_stake_amount
        }
    }

    fun settle_autobet_internal<T>(
        house: &mut House<T>,
        player: address,
        player_wins: vector<bool>,
        mut stake: Balance<T>,
        fee_rate: u128,
        ctx: &mut TxContext,
    ): u64 {
        let stake_amount = stake.value();
        let original_stake_amount = stake_amount / 2;

        let mut final_amount = 0;
        let mut i = 0;
        let num_of_bets = player_wins.length();
        let turn_amount = stake.value() / num_of_bets;

        while (num_of_bets > i) {
            let mut split_stake = stake.split(turn_amount);
            
            final_amount = final_amount + if(player_wins[i]) {
            let fee_amount = compute_fee_amount(stake_amount, fee_rate);
            let fee = split_stake.split(fee_amount);
              
            house.treasury.join(fee);
            let reward = coin::from_balance(split_stake, ctx);
            transfer::public_transfer(reward, player);
            original_stake_amount - fee_amount
            } else {
                house.pool.join(split_stake);
                original_stake_amount
            };

            i = i + 1;
        };

        // Clean dust
        if (stake.value() != 0) {
            house.pool.join(stake);
        } else {
            stake.destroy_zero();
        };

        final_amount
    }

    fun compute_win(pub_key: vector<u8>, mut msg_vec: vector<u8>, seed: vector<u8>,bls_sig: vector<u8>, guess: u8): bool {
        msg_vec.append(seed);
        assert!(
            bls12381_min_pk_verify(&bls_sig, &pub_key, &msg_vec),
            EInvalidBlsSig
        );

        let hashed_beacon = blake2b256(&bls_sig);
        (guess == hashed_beacon[0] % 2)
    }

    fun compute_fee_amount(amount: u64, fee_rate: u128): u64 {
        (((amount as u128) * fee_rate / FEE_PRECISION) as u64)
    }
    
    fun min_u128(x: u128, y: u128): u128 {
        if (x <= y) { x } else { y }
    }

    // --------------- Test only ---------------

    #[test_only]
    public fun init_for_testing(otw: COIN_FLIP_V2, ctx: &mut TxContext) {
        init(otw, ctx)
    }

    #[test_only]
    public fun settle_for_testing<T>(
        house: &mut House<T>,
        game_id: ID,
        bls_sig: vector<u8>,
        ctx: &mut TxContext,
    ): bool {
        assert!(game_exists(house, game_id), EGameNotExists);
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
  
        id.delete();

        let hashed_beacon = blake2b256(&bls_sig);
        let player_won: bool = (guess == hashed_beacon[0] % 2);

        settle_internal(house, player, player_won, stake, fee_rate, ctx);
        player_won
    }
}