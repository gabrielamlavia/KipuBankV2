# 🏦 KipuBankV2

Versión mejorada del contrato [**KipuBank** original](https://github.com/gabrielamlavia/kipu-bank/blob/main/contracts/KipuBank.sol).
Este contrato evoluciona la lógica base hacia un diseño **multi-token**, **seguro**, **modular** y **listo para producción**, aplicando buenas prácticas de arquitectura y seguridad en Solidity.

---

## 🚀 Principales Mejoras sobre KipuBank original

| Área | KipuBank (v1) | KipuBankV2 |
|------|----------------|-------------|
| **Control de Acceso** | Solo `owner` implícito | Sistema basado en roles (`AccessControl`), con `ADMIN_ROLE` y `DEFAULT_ADMIN_ROLE`. |
| **Soporte de Tokens** | Solo Ether | Soporte multi-token: ETH (`address(0)`) + ERC-20 mediante `SafeERC20`. |
| **Contabilidad Interna** | `mapping(address => uint256)` | `mapping(address => mapping(address => uint256))` — balance por usuario y token. |
| **Oráculos Chainlink** | No tenía | Agregado: conversión automática de montos a USD (USDC 6 decimales) mediante `AggregatorV3Interface`. |
| **Eventos** | Básicos | `Deposit`, `Withdrawal`, `PriceFeedSet`, `GlobalLimitSet` con valores convertidos a USD. |
| **Errores Personalizados** | Parcial | `InsufficientBalance`, `ZeroAmount`, `PriceFeedNotSet`, `InvalidAmount`. |
| **Seguridad** | `ReentrancyGuard` | Mantiene `ReentrancyGuard` + validaciones estrictas + CEI pattern. |
| **Variables** | Convencionales | Uso de `immutable` y `constant` para eficiencia de gas. |
| **Contabilidad Global** | En ETH | En **USDC**, usando precios de Chainlink. |
| **Optimización de Gas** | Limitada | Lógica refactorizada con `try/catch`, `view` y estructuras más compactas. |

---

## ⚙️ Componentes Clave

### 1. Multi-Token y Contabilidad
Cada usuario tiene un balance independiente por token:
```solidity
mapping(address => mapping(address => uint256)) private balances;
```
Se usa `address(0)` para representar ETH nativo.  
Los depósitos pueden realizarse tanto en Ether como en tokens ERC-20 compatibles.

### 2. Oráculos Chainlink
Conversión de montos a **valor USDC (6 decimales)**:
```solidity
function _convertToUSDC(address token, uint256 amount) internal view returns (uint256)
```
Cada token posee un **feed asociado** (`setPriceFeed(token, feed)`), por ejemplo:

| Token | Feed (Sepolia ejemplo) |
|--------|------------------------|
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| USDC/USD | `0x0A6513e40db6EB1b165753AD52E80663aeA50545` |

> 🔹 Los feeds pueden actualizarse según la red o el entorno de pruebas.

### 3. Límite Global
El banco define un **tope máximo en USDC**:
```solidity
uint256 public globalLimitUSDC;
```
Se impide aceptar nuevos depósitos que excedan ese valor convertido.

### 4. Seguridad
- `ReentrancyGuard` para evitar ataques de reentrada.  
- `AccessControl` para separar roles administrativos.  
- Patrón *Checks-Effects-Interactions* aplicado.  
- Transferencias nativas seguras con `.call{value: amount}("")`.

---

## 🧠 Decisiones de Diseño 

- **Conversión a USDC:** se estandarizó toda la contabilidad a 6 decimales para consistencia con stablecoins.  
- **Feeds individuales:** permite expansión a cualquier token ERC-20.  
- **Uso de `try/catch`:** evita revert global al convertir precios.  
- **No se guarda historial de transacciones** (solo eventos), para minimizar gas y mantener enfoque minimalista.  
- **Balances globales:** calculados “on-demand” para evitar acumulación de estado costosa.

---

## 🧾 Ejemplo de Uso

```solidity
// Establecer feed ETH/USD
kipuBank.setPriceFeed(address(0), 0x694AA1769357215DE4FAC081bf1f309aDC325306);

// Depositar 0.1 ETH
kipuBank.deposit{value: 0.1 ether}(address(0), 0.1 ether);

// Retirar 0.05 ETH
kipuBank.withdraw(address(0), 0.05 ether);
```
