(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u101))
(define-constant ERR_POSITION_NOT_FOUND (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_POSITION_HEALTHY (err u104))
(define-constant ERR_INVALID_PRICE (err u105))
(define-constant ERR_ALREADY_HAS_POSITION (err u106))
(define-constant ERR_INSUFFICIENT_BALANCE (err u107))
(define-constant ERR_INVALID_PERCENTAGE (err u108))
(define-constant ERR_INVALID_INCREASE (err u109))

(define-constant LIQUIDATION_THRESHOLD u8000)
(define-constant MAINTENANCE_MARGIN u1000)
(define-constant FUNDING_RATE_DIVISOR u1000000)
(define-constant PRECISION u10000)

(define-data-var stx-price uint u100000)
(define-data-var total-long-positions uint u0)
(define-data-var total-short-positions uint u0)
(define-data-var funding-rate int 0)
(define-data-var last-funding-update uint u0)

(define-map positions
    principal
    {
        collateral: uint,
        position-size: uint,
        entry-price: uint,
        is-long: bool,
        last-funding-payment: uint,
    }
)

(define-map user-balances
    principal
    uint
)

(define-read-only (get-position (user principal))
    (map-get? positions user)
)

(define-read-only (get-stx-price)
    (ok (var-get stx-price))
)

(define-read-only (get-funding-rate)
    (ok (var-get funding-rate))
)

(define-read-only (get-user-balance (user principal))
    (default-to u0 (map-get? user-balances user))
)

(define-read-only (calculate-position-value
        (position-size uint)
        (current-price uint)
    )
    (/ (* position-size current-price) PRECISION)
)

(define-read-only (calculate-pnl (user principal))
    (let (
            (position (unwrap! (map-get? positions user) (err ERR_POSITION_NOT_FOUND)))
            (current-price (var-get stx-price))
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

(define-read-only (calculate-margin-ratio (user principal))
    (let (
            (position (unwrap! (map-get? positions user) (err ERR_POSITION_NOT_FOUND)))
            (pnl (unwrap! (calculate-pnl user) (err ERR_POSITION_NOT_FOUND)))
            (collateral (get collateral position))
            (position-value (calculate-position-value (get position-size position)
                (var-get stx-price)
            ))
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

(define-read-only (is-liquidatable (user principal))
    (let ((margin-ratio-result (calculate-margin-ratio user)))
        (match margin-ratio-result
            margin-ratio (ok (< margin-ratio MAINTENANCE_MARGIN))
            error (ok false)
        )
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
        (asserts! (is-none (map-get? positions tx-sender))
            ERR_ALREADY_HAS_POSITION
        )
        (map-set user-balances tx-sender (- current-balance amount))
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (ok true)
    )
)

(define-public (open-position
        (collateral-amount uint)
        (position-size uint)
        (is-long bool)
    )
    (let (
            (current-balance (get-user-balance tx-sender))
            (current-price (var-get stx-price))
        )
        (asserts! (is-none (map-get? positions tx-sender))
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
            (map-set positions tx-sender {
                collateral: collateral-amount,
                position-size: position-size,
                entry-price: current-price,
                is-long: is-long,
                last-funding-payment: stacks-block-height,
            })
            (map-set user-balances tx-sender
                (- current-balance collateral-amount)
            )
            (if is-long
                (var-set total-long-positions
                    (+ (var-get total-long-positions) position-size)
                )
                (var-set total-short-positions
                    (+ (var-get total-short-positions) position-size)
                )
            )
            (ok true)
        )
    )
)

(define-public (increase-position
        (add-collateral uint)
        (add-size uint)
    )
    (begin
        ;; Settle funding first to ensure position state is up to date
        (try! (apply-funding-payment tx-sender))
        (let (
                (position (unwrap! (map-get? positions tx-sender) ERR_POSITION_NOT_FOUND))
                (current-size (get position-size position))
                (current-entry (get entry-price position))
                (current-collateral (get collateral position))
                (is-long (get is-long position))
                (user-balance (get-user-balance tx-sender))
                (current-price (var-get stx-price))
            )
            (asserts! (> add-size u0) ERR_INVALID_AMOUNT)
            ;; Note: add-collateral can be 0 if user has enough margin already
            (if (> add-collateral u0)
                (asserts! (>= user-balance add-collateral)
                    ERR_INSUFFICIENT_BALANCE
                )
                true
            )

            (let (
                    (total-new-size (+ current-size add-size))
                    ;; Weighted Average Entry Price Calculation
                    ;; New Entry = ((Old Size * Old Entry) + (New Size * Current Price)) / Total Size
                    (new-entry-price (/
                        (+ (* current-size current-entry)
                            (* add-size current-price)
                        )
                        total-new-size
                    ))
                    (total-new-collateral (+ current-collateral add-collateral))
                    ;; New Margin Calculation for validation
                    (new-position-value (calculate-position-value total-new-size current-price))
                    (new-margin-ratio (/ (* total-new-collateral PRECISION) new-position-value))
                )
                (asserts! (>= new-margin-ratio MAINTENANCE_MARGIN)
                    ERR_INSUFFICIENT_COLLATERAL
                )

                ;; Lock new collateral if any
                (if (> add-collateral u0)
                    (map-set user-balances tx-sender
                        (- user-balance add-collateral)
                    )
                    true
                )

                ;; Update Global State
                (if is-long
                    (var-set total-long-positions
                        (+ (var-get total-long-positions) add-size)
                    )
                    (var-set total-short-positions
                        (+ (var-get total-short-positions) add-size)
                    )
                )

                ;; Update Position State
                (map-set positions tx-sender
                    (merge position {
                        collateral: total-new-collateral,
                        position-size: total-new-size,
                        entry-price: new-entry-price,
                    })
                )

                (ok true)
            )
        )
    )
)

(define-public (close-position)
    (let (
            (position (unwrap! (map-get? positions tx-sender) ERR_POSITION_NOT_FOUND))
            (pnl (unwrap! (calculate-pnl tx-sender) ERR_POSITION_NOT_FOUND))
            (collateral (get collateral position))
            (position-size (get position-size position))
            (is-long (get is-long position))
            (current-balance (get-user-balance tx-sender))
        )
        (let ((final-balance (if (> pnl 0)
                (+ collateral (to-uint pnl))
                (if (>= collateral (to-uint (- 0 pnl)))
                    (- collateral (to-uint (- 0 pnl)))
                    u0
                )
            )))
            (map-set user-balances tx-sender (+ current-balance final-balance))
            (map-delete positions tx-sender)
            (if is-long
                (var-set total-long-positions
                    (- (var-get total-long-positions) position-size)
                )
                (var-set total-short-positions
                    (- (var-get total-short-positions) position-size)
                )
            )
            (ok final-balance)
        )
    )
)

(define-public (partial-close-position (percentage uint))
    (let (
            (position (unwrap! (map-get? positions tx-sender) ERR_POSITION_NOT_FOUND))
            (pnl (unwrap! (calculate-pnl tx-sender) ERR_POSITION_NOT_FOUND))
            (collateral (get collateral position))
            (position-size (get position-size position))
            (is-long (get is-long position))
            (current-balance (get-user-balance tx-sender))
        )
        (asserts! (and (>= percentage u1) (<= percentage u99))
            ERR_INVALID_PERCENTAGE
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
            (map-set positions tx-sender
                (merge position {
                    collateral: remaining-collateral,
                    position-size: remaining-size,
                })
            )
            (if is-long
                (var-set total-long-positions
                    (- (var-get total-long-positions) partial-size)
                )
                (var-set total-short-positions
                    (- (var-get total-short-positions) partial-size)
                )
            )
            (ok freed-balance)
        )
    )
)

(define-public (liquidate (user principal))
    (let (
            (liquidatable (unwrap! (is-liquidatable user) ERR_POSITION_NOT_FOUND))
            (position (unwrap! (map-get? positions user) ERR_POSITION_NOT_FOUND))
            (position-size (get position-size position))
            (is-long (get is-long position))
            (liquidator-balance (get-user-balance tx-sender))
        )
        (asserts! liquidatable ERR_POSITION_HEALTHY)
        (map-delete positions user)
        (map-set user-balances user u0)
        (let ((liquidation-reward (/ (get collateral position) u10)))
            (map-set user-balances tx-sender
                (+ liquidator-balance liquidation-reward)
            )
            (if is-long
                (var-set total-long-positions
                    (- (var-get total-long-positions) position-size)
                )
                (var-set total-short-positions
                    (- (var-get total-short-positions) position-size)
                )
            )
            (ok liquidation-reward)
        )
    )
)

(define-public (update-stx-price (new-price uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> new-price u0) ERR_INVALID_PRICE)
        (var-set stx-price new-price)
        (ok true)
    )
)

(define-public (update-funding-rate)
    (let (
            (total-long (var-get total-long-positions))
            (total-short (var-get total-short-positions))
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
                (var-set funding-rate rate)
                (var-set last-funding-update stacks-block-height)
                (ok true)
            )
            (begin
                (var-set funding-rate 0)
                (var-set last-funding-update stacks-block-height)
                (ok true)
            )
        )
    )
)

(define-public (apply-funding-payment (user principal))
    (let (
            (position (unwrap! (map-get? positions user) ERR_POSITION_NOT_FOUND))
            (blocks-elapsed (- stacks-block-height (get last-funding-payment position)))
            (funding (var-get funding-rate))
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
                (map-set positions user
                    (merge position {
                        collateral: new-collateral,
                        last-funding-payment: stacks-block-height,
                    })
                )
                (ok new-collateral)
            )
            (ok (get collateral position))
        )
    )
)
