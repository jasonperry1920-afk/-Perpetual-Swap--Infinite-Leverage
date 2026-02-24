(use-trait oracle-trait .oracle-trait.oracle-trait)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u101))
(define-constant ERR_POSITION_NOT_FOUND (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_POSITION_HEALTHY (err u104))
(define-constant ERR_ALREADY_HAS_POSITION (err u106))
(define-constant ERR_INSUFFICIENT_BALANCE (err u107))
(define-constant ERR_INVALID_PERCENTAGE (err u108))
(define-constant ERR_INVALID_INCREASE (err u109))
(define-constant ERR_MARKET_NOT_FOUND (err u110))
(define-constant ERR_UNAUTHORIZED_ORACLE (err u111))
(define-constant ERR_ORACLE_PRICE_FAILED (err u112))

(define-constant LIQUIDATION_THRESHOLD u8000)
(define-constant MAINTENANCE_MARGIN u1000)
(define-constant FUNDING_RATE_DIVISOR u1000000)
(define-constant PRECISION u10000)

(define-data-var market-count uint u0)
(define-data-var global-locked-collateral uint u0)

(define-map markets
    uint
    {
        asset-name: (string-ascii 32),
        total-long-oi: uint,
        total-short-oi: uint,
        funding-rate: int,
        last-funding-update: uint
    }
)

(define-map positions
    { user: principal, market-id: uint }
    {
        collateral: uint,
        position-size: uint,
        entry-price: uint,
        is-long: bool,
        last-funding-payment: uint
    }
)

(define-map user-balances
    principal
    uint
)

(define-map user-open-positions
    principal
    uint
)

(define-map authorized-oracles
    principal
    bool
)

(define-read-only (get-market (market-id uint))
    (map-get? markets market-id)
)

(define-read-only (get-position (user principal) (market-id uint))
    (map-get? positions { user: user, market-id: market-id })
)

(define-read-only (get-user-balance (user principal))
    (default-to u0 (map-get? user-balances user))
)

(define-read-only (get-user-open-positions (user principal))
    (default-to u0 (map-get? user-open-positions user))
)

(define-read-only (is-oracle-authorized (oracle principal))
    (default-to false (map-get? authorized-oracles oracle))
)

(define-read-only (get-global-locked-collateral)
    (var-get global-locked-collateral)
)

(define-read-only (calculate-position-value
        (position-size uint)
        (current-price uint)
    )
    (/ (* position-size current-price) PRECISION)
)

(define-read-only (calculate-pnl (user principal) (market-id uint) (current-price uint))
    (let (
            (position (unwrap! (get-position user market-id) (err ERR_POSITION_NOT_FOUND)))
            (entry-price (get entry-price position))
            (position-size (get position-size position))
            (is-long (get is-long position))
        )
        (if is-long
            (ok (if (>= current-price entry-price)
                (to-int (/ (* position-size (- current-price entry-price)) PRECISION))
                (- 0
                    (to-int (/ (* position-size (- entry-price current-price)) PRECISION))
                )
            ))
            (ok (if (>= entry-price current-price)
                (to-int (/ (* position-size (- entry-price current-price)) PRECISION))
                (- 0
                    (to-int (/ (* position-size (- current-price entry-price)) PRECISION))
                )
            ))
        )
    )
)

(define-read-only (calculate-margin-ratio (user principal) (market-id uint) (current-price uint))
    (let (
            (position (unwrap! (get-position user market-id) (err ERR_POSITION_NOT_FOUND)))
            (pnl (unwrap! (calculate-pnl user market-id current-price) (err ERR_POSITION_NOT_FOUND)))
            (collateral (get collateral position))
            (position-value (calculate-position-value (get position-size position) current-price))
        )
        (if (> pnl 0)
            (ok (/ (* (+ collateral (to-uint pnl)) PRECISION) position-value))
            (ok (if (>= collateral (to-uint (- 0 pnl)))
                (/ (* (- collateral (to-uint (- 0 pnl))) PRECISION)
                    position-value
                )
                u0
            ))
        )
    )
)

(define-read-only (is-liquidatable (user principal) (market-id uint) (current-price uint))
    (let ((margin-ratio-result (calculate-margin-ratio user market-id current-price)))
        (match margin-ratio-result
            margin-ratio (ok (< margin-ratio MAINTENANCE_MARGIN))
            error (ok false)
        )
    )
)

(define-read-only (get-account-leverage (user principal) (market-id uint) (current-price uint))
    (let (
            (position (unwrap! (get-position user market-id) (err ERR_POSITION_NOT_FOUND)))
            (position-value (calculate-position-value (get position-size position) current-price))
            (pnl-result (calculate-pnl user market-id current-price))
        )
        (match pnl-result
            pnl (let ((equity (if (> pnl 0)
                    (+ (get collateral position) (to-uint pnl))
                    (if (>= (get collateral position) (to-uint (- 0 pnl)))
                        (- (get collateral position) (to-uint (- 0 pnl)))
                        u0
                    )
                )))
                (if (> equity u0)
                    (ok (/ (* position-value PRECISION) equity))
                    (ok u0)
                )
            )
            error (err error)
        )
    )
)

(define-read-only (get-max-withdrawable-margin (user principal) (market-id uint) (current-price uint))
    (let (
            (position (unwrap! (get-position user market-id) (err ERR_POSITION_NOT_FOUND)))
            (position-value (calculate-position-value (get position-size position) current-price))
            (min-margin (/ (* position-value MAINTENANCE_MARGIN) PRECISION))
            (pnl-result (calculate-pnl user market-id current-price))
        )
        (match pnl-result
            pnl (let ((equity (if (> pnl 0)
                    (+ (get collateral position) (to-uint pnl))
                    (if (>= (get collateral position) (to-uint (- 0 pnl)))
                        (- (get collateral position) (to-uint (- 0 pnl)))
                        u0
                    )
                )))
                (if (> equity min-margin)
                    (let ((surplus (- equity min-margin)))
                        (if (> surplus (get collateral position))
                            (ok (get collateral position))
                            (ok surplus)
                        )
                    )
                    (ok u0)
                )
            )
            error (err error)
        )
    )
)

(define-public (set-oracle-authorization (oracle principal) (authorized bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (ok (map-set authorized-oracles oracle authorized))
    )
)

(define-public (deposit (amount uint))
    (let ((current-balance (get-user-balance tx-sender)))
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set user-balances tx-sender (+ current-balance amount))
        (ok true)
    )
)

(define-public (withdraw (amount uint))
    (let ((current-balance (get-user-balance tx-sender)))
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (is-eq (get-user-open-positions tx-sender) u0)
            ERR_ALREADY_HAS_POSITION
        )
        (map-set user-balances tx-sender (- current-balance amount))
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (ok true)
    )
)

(define-public (create-market (asset-name (string-ascii 32)))
    (let ((new-market-id (+ (var-get market-count) u1)))
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (map-set markets new-market-id {
            asset-name: asset-name,
            total-long-oi: u0,
            total-short-oi: u0,
            funding-rate: 0,
            last-funding-update: stacks-block-height
        })
        (var-set market-count new-market-id)
        (ok new-market-id)
    )
)

(define-public (open-position
        (market-id uint)
        (collateral-amount uint)
        (position-size uint)
        (is-long bool)
        (oracle <oracle-trait>)
    )
    (let (
            (current-balance (get-user-balance tx-sender))
            (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
            (open-positions-count (get-user-open-positions tx-sender))
        )
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (let ((current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED)))
            (asserts! (is-none (get-position tx-sender market-id))
                ERR_ALREADY_HAS_POSITION
            )
            (asserts! (> collateral-amount u0) ERR_INVALID_AMOUNT)
            (asserts! (> position-size u0) ERR_INVALID_AMOUNT)
            (asserts! (>= current-balance collateral-amount) ERR_INSUFFICIENT_BALANCE)
            (let (
                    (position-value (calculate-position-value position-size current-price))
                    (initial-margin-ratio (/ (* collateral-amount PRECISION) position-value))
                )
                (asserts! (>= initial-margin-ratio MAINTENANCE_MARGIN)
                    ERR_INSUFFICIENT_COLLATERAL
                )
                (map-set positions { user: tx-sender, market-id: market-id } {
                    collateral: collateral-amount,
                    position-size: position-size,
                    entry-price: current-price,
                    is-long: is-long,
                    last-funding-payment: stacks-block-height
                })
                (map-set user-balances tx-sender
                    (- current-balance collateral-amount)
                )
                (var-set global-locked-collateral (+ (var-get global-locked-collateral) collateral-amount))
                (map-set user-open-positions tx-sender (+ open-positions-count u1))
                (map-set markets market-id
                    (merge market {
                        total-long-oi: (if is-long (+ (get total-long-oi market) position-size) (get total-long-oi market)),
                        total-short-oi: (if is-long (get total-short-oi market) (+ (get total-short-oi market) position-size))
                    })
                )
                (ok true)
            )
        )
    )
)

(define-public (increase-position
        (market-id uint)
        (add-collateral uint)
        (add-size uint)
        (oracle <oracle-trait>)
    )
    (begin
        (try! (apply-funding-payment tx-sender market-id))
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (let (
                (current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED))
                (position (unwrap! (get-position tx-sender market-id) ERR_POSITION_NOT_FOUND))
                (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
                (current-size (get position-size position))
                (current-entry (get entry-price position))
                (current-collateral (get collateral position))
                (is-long (get is-long position))
                (user-balance (get-user-balance tx-sender))
            )
            (asserts! (> add-size u0) ERR_INVALID_AMOUNT)
            (if (> add-collateral u0)
                (asserts! (>= user-balance add-collateral)
                    ERR_INSUFFICIENT_BALANCE
                )
                true
            )

            (let (
                    (total-new-size (+ current-size add-size))
                    (new-entry-price (/
                        (+ (* current-size current-entry)
                            (* add-size current-price)
                        )
                        total-new-size
                    ))
                    (total-new-collateral (+ current-collateral add-collateral))
                    (new-position-value (calculate-position-value total-new-size current-price))
                    (new-margin-ratio (/ (* total-new-collateral PRECISION) new-position-value))
                )
                (asserts! (>= new-margin-ratio MAINTENANCE_MARGIN)
                    ERR_INSUFFICIENT_COLLATERAL
                )

                (if (> add-collateral u0)
                    (begin
                        (map-set user-balances tx-sender
                            (- user-balance add-collateral)
                        )
                        (var-set global-locked-collateral (+ (var-get global-locked-collateral) add-collateral))
                    )
                    true
                )

                (map-set markets market-id
                    (merge market {
                        total-long-oi: (if is-long (+ (get total-long-oi market) add-size) (get total-long-oi market)),
                        total-short-oi: (if is-long (get total-short-oi market) (+ (get total-short-oi market) add-size))
                    })
                )

                (map-set positions { user: tx-sender, market-id: market-id }
                    (merge position {
                        collateral: total-new-collateral,
                        position-size: total-new-size,
                        entry-price: new-entry-price
                    })
                )

                (ok true)
            )
        )
    )
)

(define-public (add-margin (market-id uint) (amount uint))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (apply-funding-payment tx-sender market-id))
        (let (
                (position (unwrap! (get-position tx-sender market-id) ERR_POSITION_NOT_FOUND))
                (user-balance (get-user-balance tx-sender))
            )
            (asserts! (>= user-balance amount) ERR_INSUFFICIENT_BALANCE)
            (map-set user-balances tx-sender (- user-balance amount))
            (map-set positions { user: tx-sender, market-id: market-id }
                (merge position {
                    collateral: (+ (get collateral position) amount)
                })
            )
            (var-set global-locked-collateral (+ (var-get global-locked-collateral) amount))
            (ok true)
        )
    )
)

(define-public (remove-margin (market-id uint) (amount uint) (oracle <oracle-trait>))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (try! (apply-funding-payment tx-sender market-id))
        (let (
                (current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED))
                (position (unwrap! (get-position tx-sender market-id) ERR_POSITION_NOT_FOUND))
                (user-balance (get-user-balance tx-sender))
                (max-withdrawable (unwrap! (get-max-withdrawable-margin tx-sender market-id current-price) ERR_POSITION_NOT_FOUND))
            )
            (asserts! (<= amount max-withdrawable) ERR_INSUFFICIENT_COLLATERAL)
            (map-set user-balances tx-sender (+ user-balance amount))
            (map-set positions { user: tx-sender, market-id: market-id }
                (merge position {
                    collateral: (- (get collateral position) amount)
                })
            )
            (var-set global-locked-collateral (- (var-get global-locked-collateral) amount))
            (ok true)
        )
    )
)

(define-public (close-position (market-id uint) (oracle <oracle-trait>))
    (begin
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (let (
                (current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED))
                (position (unwrap! (get-position tx-sender market-id) ERR_POSITION_NOT_FOUND))
                (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
                (pnl (unwrap! (calculate-pnl tx-sender market-id current-price) ERR_POSITION_NOT_FOUND))
                (collateral (get collateral position))
                (position-size (get position-size position))
                (is-long (get is-long position))
                (current-balance (get-user-balance tx-sender))
                (open-positions-count (get-user-open-positions tx-sender))
            )
            (let ((final-balance (if (> pnl 0)
                    (+ collateral (to-uint pnl))
                    (if (>= collateral (to-uint (- 0 pnl)))
                        (- collateral (to-uint (- 0 pnl)))
                        u0
                    )
                )))
                (map-set user-balances tx-sender (+ current-balance final-balance))
                (map-delete positions { user: tx-sender, market-id: market-id })
                (map-set user-open-positions tx-sender (- open-positions-count u1))
                (var-set global-locked-collateral (- (var-get global-locked-collateral) collateral))
                
                (map-set markets market-id
                    (merge market {
                        total-long-oi: (if is-long (- (get total-long-oi market) position-size) (get total-long-oi market)),
                        total-short-oi: (if is-long (get total-short-oi market) (- (get total-short-oi market) position-size))
                    })
                )
                (ok final-balance)
            )
        )
    )
)

(define-public (partial-close-position (market-id uint) (percentage uint) (oracle <oracle-trait>))
    (begin
        (asserts! (and (>= percentage u1) (<= percentage u99))
            ERR_INVALID_PERCENTAGE
        )
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (let (
                (current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED))
                (position (unwrap! (get-position tx-sender market-id) ERR_POSITION_NOT_FOUND))
                (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
                (pnl (unwrap! (calculate-pnl tx-sender market-id current-price) ERR_POSITION_NOT_FOUND))
                (collateral (get collateral position))
                (position-size (get position-size position))
                (is-long (get is-long position))
                (current-balance (get-user-balance tx-sender))
            )
            (let (
                    (partial-pnl (/ (* pnl (to-int percentage)) 100))
                    (partial-collateral (/ (* collateral percentage) u100))
                    (partial-size (/ (* position-size percentage) u100))
                    (remaining-collateral (- collateral partial-collateral))
                    (remaining-size (- position-size partial-size))
                    (freed-balance (if (> partial-pnl 0)
                        (+ partial-collateral (to-uint partial-pnl))
                        (if (>= partial-collateral (to-uint (- 0 partial-pnl)))
                            (- partial-collateral (to-uint (- 0 partial-pnl)))
                            u0
                        )
                    ))
                )
                (map-set user-balances tx-sender (+ current-balance freed-balance))
                (map-set positions { user: tx-sender, market-id: market-id }
                    (merge position {
                        collateral: remaining-collateral,
                        position-size: remaining-size
                    })
                )
                (var-set global-locked-collateral (- (var-get global-locked-collateral) partial-collateral))
                
                (map-set markets market-id
                    (merge market {
                        total-long-oi: (if is-long (- (get total-long-oi market) partial-size) (get total-long-oi market)),
                        total-short-oi: (if is-long (get total-short-oi market) (- (get total-short-oi market) partial-size))
                    })
                )
                (ok freed-balance)
            )
        )
    )
)

(define-public (liquidate (user principal) (market-id uint) (oracle <oracle-trait>))
    (begin
        (asserts! (is-oracle-authorized (contract-of oracle)) ERR_UNAUTHORIZED_ORACLE)
        (let (
                (current-price (unwrap! (contract-call? oracle get-price market-id) ERR_ORACLE_PRICE_FAILED))
                (liquidatable (unwrap! (is-liquidatable user market-id current-price) ERR_POSITION_NOT_FOUND))
                (position (unwrap! (get-position user market-id) ERR_POSITION_NOT_FOUND))
                (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
                (position-size (get position-size position))
                (is-long (get is-long position))
                (liquidator-balance (get-user-balance tx-sender))
                (open-positions-count (get-user-open-positions user))
            )
            (asserts! liquidatable ERR_POSITION_HEALTHY)
            (map-delete positions { user: user, market-id: market-id })
            (map-set user-open-positions user (- open-positions-count u1))
            (var-set global-locked-collateral (- (var-get global-locked-collateral) (get collateral position)))
            
            (let ((liquidation-reward (/ (get collateral position) u10)))
                (map-set user-balances tx-sender
                    (+ liquidator-balance liquidation-reward)
                )
                
                (map-set markets market-id
                    (merge market {
                        total-long-oi: (if is-long (- (get total-long-oi market) position-size) (get total-long-oi market)),
                        total-short-oi: (if is-long (get total-short-oi market) (- (get total-short-oi market) position-size))
                    })
                )
                (ok liquidation-reward)
            )
        )
    )
)

(define-public (update-funding-rate (market-id uint))
    (let (
            (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
            (total-long (get total-long-oi market))
            (total-short (get total-short-oi market))
            (total-positions (+ total-long total-short))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (if (> total-positions u0)
            (let (
                    (imbalance (if (> total-long total-short)
                        (to-int (- total-long total-short))
                        (- 0 (to-int (- total-short total-long)))
                    ))
                    (rate (/ (* imbalance (to-int PRECISION)) (to-int total-positions)))
                )
                (map-set markets market-id
                    (merge market {
                        funding-rate: rate,
                        last-funding-update: stacks-block-height
                    })
                )
                (ok true)
            )
            (begin
                (map-set markets market-id
                    (merge market {
                        funding-rate: 0,
                        last-funding-update: stacks-block-height
                    })
                )
                (ok true)
            )
        )
    )
)

(define-public (apply-funding-payment (user principal) (market-id uint))
    (let (
            (position (unwrap! (get-position user market-id) ERR_POSITION_NOT_FOUND))
            (market (unwrap! (get-market market-id) ERR_MARKET_NOT_FOUND))
            (blocks-elapsed (- stacks-block-height (get last-funding-payment position)))
            (funding (get funding-rate market))
            (position-size (get position-size position))
            (is-long (get is-long position))
        )
        (if (> blocks-elapsed u0)
            (let (
                    (payment-calc (/
                        (*
                            (if (> funding 0)
                                (to-uint funding)
                                (to-uint (- 0 funding))
                            )
                            position-size blocks-elapsed
                        )
                        FUNDING_RATE_DIVISOR
                    ))
                    (collateral (get collateral position))
                    (should-deduct (or (and is-long (> funding 0)) (and (not is-long) (< funding 0))))
                    (new-collateral (if should-deduct
                        (if (>= collateral payment-calc)
                            (- collateral payment-calc)
                            u0
                        )
                        (+ collateral payment-calc)
                    ))
                )
                (map-set positions { user: user, market-id: market-id }
                    (merge position {
                        collateral: new-collateral,
                        last-funding-payment: stacks-block-height
                    })
                )
                (var-set global-locked-collateral (if (>= new-collateral collateral)
                    (+ (var-get global-locked-collateral) (- new-collateral collateral))
                    (if (>= (var-get global-locked-collateral) (- collateral new-collateral))
                        (- (var-get global-locked-collateral) (- collateral new-collateral))
                        u0
                    )
                ))
                (ok new-collateral)
            )
            (ok (get collateral position))
        )
    )
)