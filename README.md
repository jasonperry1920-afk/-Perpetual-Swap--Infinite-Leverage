# 📊 Perpetual Swap Contract

> A decentralized perpetual swap protocol enabling infinite leverage trading on STX with automatic liquidation and funding rates

## 🎯 What is This?

This smart contract implements a perpetual swap (perp) trading system where users can open leveraged long or short positions on STX without expiration dates. Positions remain open indefinitely as long as margin requirements are maintained.

## ✨ Key Features

- 💰 **Collateralized Trading** - Deposit STX as collateral to open positions
- 📈 **Long & Short Positions** - Bet on STX price going up or down
- ⚖️ **Perpetual Mechanics** - No expiration, positions stay open indefinitely
- ⚠️ **Automatic Liquidation** - Undercollateralized positions get liquidated
- 💸 **Funding Rates** - Dynamic funding payments based on market imbalance
- 🔒 **Margin Requirements** - Maintenance margin enforced at 10%

## 🔧 Core Concepts

**Margin Ratio**: The ratio of your collateral (adjusted for PnL) to position value. Must stay above 10% to avoid liquidation.

**Funding Rate**: A periodic payment between longs and shorts that balances market imbalance. When longs > shorts, longs pay shorts and vice versa.

**Liquidation**: When margin ratio falls below 10%, anyone can liquidate the position and earn 10% of remaining collateral as reward.

**Position Size**: The notional value of your position. Higher size = higher leverage = higher risk.

## 🚀 Usage

### Depositing Collateral

```clarity
(contract-call? .perpetual-swap deposit u10000000)
```

Deposit STX tokens into your account balance. Required before opening positions.

### Opening a Position

```clarity
(contract-call? .perpetual-swap open-position u5000000 u50000000 true)
```

Parameters:
- `collateral-amount`: Amount of collateral to use (in micro-STX)
- `position-size`: Notional size of position (in micro-STX)
- `is-long`: `true` for long (bullish), `false` for short (bearish)

### Closing a Position

```clarity
(contract-call? .perpetual-swap close-position)
```

Close your position and realize profits or losses. Collateral + PnL returned to your balance.

### Withdrawing Funds

```clarity
(contract-call? .perpetual-swap withdraw u5000000)
```

Withdraw STX from your account balance. Only possible when you have no open position.

### Liquidating Undercollateralized Positions

```clarity
(contract-call? .perpetual-swap liquidate 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

Anyone can liquidate positions below maintenance margin and earn 10% reward.

## 📊 Read-Only Functions

### Check Position Details

```clarity
(contract-call? .perpetual-swap get-position tx-sender)
```

Returns your position data: collateral, size, entry price, direction, and last funding payment block.

### Calculate PnL

```clarity
(contract-call? .perpetual-swap calculate-pnl tx-sender)
```

Get current unrealized profit or loss on your position.

### Check Margin Ratio

```clarity
(contract-call? .perpetual-swap calculate-margin-ratio tx-sender)
```

Returns your current margin ratio (scaled by 10000). Value < 1000 means liquidatable.

### Check if Liquidatable

```clarity
(contract-call? .perpetual-swap is-liquidatable 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

Returns `true` if position can be liquidated.

### Get Current STX Price

```clarity
(contract-call? .perpetual-swap get-stx-price)
```

Returns the current oracle price used for calculations.

### Get Funding Rate

```clarity
(contract-call? .perpetual-swap get-funding-rate)
```

Returns the current funding rate (can be positive or negative).

## 🛡️ Admin Functions

### Update STX Price (Oracle)

```clarity
(contract-call? .perpetual-swap update-stx-price u105000)
```

Contract owner updates the STX price oracle. In production, this should use a decentralized oracle.

### Update Funding Rate

```clarity
(contract-call? .perpetual-swap update-funding-rate)
```

Calculates and updates the funding rate based on long/short imbalance.

### Apply Funding Payment

```clarity
(contract-call? .perpetual-swap apply-funding-payment 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

Applies accumulated funding payments to a user's position.

## ⚙️ Constants

- `LIQUIDATION_THRESHOLD`: 80% (initial margin requirement)
- `MAINTENANCE_MARGIN`: 10% (minimum margin before liquidation)
- `PRECISION`: 10000 (for decimal math)
- `FUNDING_RATE_DIVISOR`: 1000000 (funding rate precision)

## 🎓 Learning Objectives

This contract demonstrates:

- ✅ Perpetual swap mechanics and unlimited leverage
- ✅ Margin ratio calculations and monitoring
- ✅ Automated liquidation triggers and incentives
- ✅ Dynamic funding rate mechanisms
- ✅ Position management and PnL tracking
- ✅ Collateral management and risk controls

## ⚠️ Important Notes

- 🔴 This is an MVP for educational purposes
- 🔴 Price oracle is centralized (owner-controlled)
- 🔴 No circuit breakers or emergency stops
- 🔴 Funding rates must be manually updated
- 🔴 Maximum one position per user
- 🔴 Not audited - do not use in production with real funds

## 📝 Testing

Deploy the contract with Clarinet and test the core flows:

1. Deposit collateral
2. Open long/short positions
3. Simulate price movements
4. Test liquidations
5. Apply funding payments
6. Close positions with profit/loss

## 🤝 Contributing

Feel free to extend this MVP with:

- Multiple positions per user
- Decentralized price oracles
- Automatic funding rate updates
- Take profit / stop loss orders
- Position size limits and risk controls
- Emergency pause mechanisms

## 📄 License

MIT