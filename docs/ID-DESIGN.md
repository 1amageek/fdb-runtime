# ID Design Document

このドキュメントは、fdb-runtimeにおけるID（識別子）の設計について説明します。

## 背景

### FoundationDBの本質

FoundationDBはkey-valueストアです。すべてのデータは本質的にユニークなキーを持っています。

```
[key] = [value]
```

これはRDBMSの「PrimaryKey」とは根本的に異なります。RDBMSではテーブル内の行を識別するためにPrimaryKeyが必要ですが、FDBではキー自体がデータの識別子として機能します。

### 従来の設計の問題点

従来の設計では`#PrimaryKey`マクロを使用していました：

```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    var userID: Int64
    var name: String
}
```

**問題点**:

1. **概念の混乱**: FDBはkey-valueストアなのに、RDBMSの「PrimaryKey」概念を持ち込んでいた
2. **複合キーの必要性が不明確**: `#PrimaryKey<User>([\.country, \.userID])` のような複合キーは本当に必要か？
3. **Directoryとの役割重複**: マルチテナントは`#Directory`の`Field()`で対応可能
4. **上位レイヤーとの境界が曖昧**: record-layerの概念をfdb-runtimeに持ち込んでいた

## 設計の議論

### 複合キーは必要か？

複合キーの一般的なユースケースを検証しました：

| ユースケース | 複合キーでの解決 | FDBでの代替手段 |
|-------------|-----------------|----------------|
| マルチテナント | `[tenantID, userID]` | `#Directory` + `Field(\.tenantID)` |
| 親子関係 | `[parentID, childID]` | `#Index([\.parentID])` |
| 時系列データ | `[entityID, timestamp]` | `#Index([\.entityID, \.timestamp])` |
| 自然キー | `[country, postalCode]` | `#Index([...], unique: true)` |

**結論**: 複合キーはすべて`#Directory`と`#Index`で代替可能。

### Firestoreとの比較

Firestoreの設計を参考にしました：

| 概念 | Firestore | fdb-runtime |
|-----|-----------|-------------|
| 一意識別子 | documentId（単一） | `id`フィールド（単一） |
| 複合インデックス | サポート | `#Index([\.a, \.b])` |
| 複合PrimaryKey | なし | なし（廃止） |

Firestoreでも：
- すべてのドキュメントは単一のdocumentIdを持つ
- 複合キーはPrimaryKeyではなく、インデックスで対応

### ULIDの選択理由

ID生成方式を検討しました：

| 方式 | 時系列ソート | サイズ | クライアント生成 | 衝突リスク |
|-----|------------|-------|----------------|-----------|
| UUID v4 | 不可 | 36文字 | 可能 | なし |
| ULID | 可能 | 26文字 | 可能 | なし |
| 連番 | 可能 | 可変 | 不可（サーバー必要） | あり（競合） |

**ULIDの利点**:
- **クライアント生成**: サーバー不要で即座に生成可能
- **衝突防止**: 分散環境でも衝突しない
- **時系列ソート可能**: 先頭48ビットがタイムスタンプ
- **コンパクト**: 26文字（UUID: 36文字）
- **事前にID保持可能**: 関連オブジェクトを作成できる

**結論**: ULIDを採用。

## 確定した設計

### 基本構造

```swift
@Persistable
struct User {
    // ID: 自動生成（ULID）、initに含めない
    var id: String = ULID().ulidString

    // Directory: 格納場所
    #Directory<User>("users")

    // Index: セカンダリインデックス（複合対応）
    #Index<User>([\.email], unique: true)
    #Index<User>([\.category, \.createdAt])

    var email: String
    var category: String
    var createdAt: Date
}
```

### IDの扱い

#### 自動生成（デフォルト）

ユーザーが`id`フィールドを定義しない場合、マクロが自動的に追加します。

```swift
@Persistable
struct Log {
    var message: String
    var timestamp: Date
}

// マクロ展開後:
struct Log {
    var id: String = ULID().ulidString  // 自動追加
    var message: String
    var timestamp: Date
}

// 生成されるinit（idは含まない）
init(message: String, timestamp: Date) {
    self.message = message
    self.timestamp = timestamp
    // idは自動的にULIDで初期化
}
```

#### ユーザー定義の場合

ユーザーが`id`フィールドを定義した場合、その型と値を使用します。
型は`TupleElement`に準拠していれば自由です。

```swift
@Persistable
struct User {
    var id: String = ULID().ulidString  // String
    var name: String
}

@Persistable
struct Product {
    var id: Int64  // Int64
    var name: String
}

@Persistable
struct Item {
    var id: UUID = UUID()  // UUID
    var name: String
}
```

**重要**: ユーザー定義の場合でも、`id`は初期化インターフェースに含めません。

```swift
// 生成されるinit
init(name: String) {
    self.name = name
    // idは自動的にデフォルト値で初期化
}

// これは生成しない
// init(id: String, name: String) ← NG
```

### 初期化インターフェース

`id`フィールドは初期化インターフェースに含めません。これにより：

1. **一貫性**: IDは常に自動生成される
2. **安全性**: ユーザーが不正なIDを設定することを防ぐ
3. **シンプル**: 初期化時にIDを考慮する必要がない

```swift
// 使用例
let user = User(name: "Alice", email: "alice@example.com")
print(user.id)  // ULIDが自動設定済み

// 関連オブジェクトも即座に作れる
let order = Order(userID: user.id, product: "Widget")
```

### var推奨

`id`フィールドは`var`で宣言します：

```swift
var id: String = ULID().ulidString  // var（letではない）
```

理由：
- Structの一貫性（他のフィールドと同様にvar）
- Codableデコード時の柔軟性

### @Persistable(type:)

リネーム時のキー安定性のため、`type`パラメータをサポートします：

```swift
@Persistable(type: "User")
struct Member {
    var id: String = ULID().ulidString
    var name: String
}

// persistableType = "User"（リネームしても変わらない）
// FDBキー: [R]/User/[id]
```

**使用ケース**:
- Struct名をリファクタリングする際、既存データとの互換性を保つ
- 明示的な型名を使用したい場合

### 一意性制約とatomic操作

#### IDの一意性

ULIDはクライアントで生成され、衝突しません。したがって：
- **idの一意性チェックは不要**
- ULIDの設計自体が衝突を防ぐ

#### unique: trueインデックス

`unique: true`インデックスは、FDBのatomic操作で実装します：

```swift
#Index<User>([\.email], unique: true)
```

**実装**:
```
// ユニークインデックスの構造
[I]/User_email_unique/[email] = [id]

// 保存時:
// 1. FDBのatomic compare-and-set操作
// 2. 既存値がない、または自分のidと一致する場合のみ書き込み成功
// 3. 競合時はトランザクション失敗 → 自動リトライ
// 4. リトライ後も制約違反ならUniqueConstraintViolationエラー
```

**競合時の挙動**:
```
Transaction A: save(User(email: "alice@example.com"))
Transaction B: save(User(email: "alice@example.com"))

Timeline:
1. A: atomic write → success
2. B: atomic write → conflict detected → retry
3. B: retry → constraint violation → UniqueConstraintViolationエラー
```

### Persistableプロトコル

```swift
public protocol Persistable: Sendable, Codable {
    associatedtype ID: Sendable & Hashable & Codable
    var id: ID { get }

    static var persistableType: String { get }
    static var allFields: [String] { get }
    static var indexDescriptors: [IndexDescriptor] { get }
}
```

### 型制約

`id`の型はコンパイル時に`Sendable & Hashable & Codable`に準拠している必要があります。

**ランタイム検証**: FDBRuntime（サーバー側）で使用する場合、ID型が`TupleElement`に準拠しているかをランタイムで検証します。これはFDBModelがプラットフォーム非依存（iOS/macOSクライアント）であるため、コンパイル時に強制できません。

**許容される型**:
- `String`
- `Int`, `Int64`, `Int32`, `Int16`, `Int8`
- `UInt`, `UInt64`, `UInt32`, `UInt16`, `UInt8`
- `Float`, `Double`
- `Bool`
- `UUID`
- `Data` / `[UInt8]`

**ソート順の注意**:

| 型 | ソート順 | 備考 |
|---|--------|------|
| String (ULID) | 時系列順 | 推奨 |
| Int64 | 数値順 | 意味のある順序がある場合 |
| UUID | バイト順 | **時系列ではない** |

```swift
// 注意: UUIDは時系列順にならない
var id: UUID = UUID()  // ソート順 ≠ 作成順

// 時系列が必要ならULID推奨
var id: String = ULID().ulidString  // ソート順 ≈ 作成順
```

### FDBキー構造

```
// データ
[directory]/R/[persistableType]/[id] = serialized_data

// インデックス
[directory]/I/[indexName]/[indexValue]/[id] = ''

// ユニークインデックス
[directory]/I/[indexName]_unique/[indexValue] = [id]
```

例：
```
[users]/R/User/01HXK5M3N2P4Q5R6S7T8U9V0WX = {name: "Alice", email: "alice@example.com"}
[users]/I/User_email/alice@example.com/01HXK5M3N2P4Q5R6S7T8U9V0WX = ''
[users]/I/User_email_unique/alice@example.com = 01HXK5M3N2P4Q5R6S7T8U9V0WX
```

## 変更点のまとめ

| 項目 | 変更前 | 変更後 |
|-----|-------|-------|
| `#PrimaryKey` | 存在（必須） | **廃止** |
| `id`フィールド | なし | **必須**（マクロ管理、var） |
| ID初期化 | - | **initに含めない** |
| 複合キー | `#PrimaryKey([\.a, \.b])` | **廃止**（Indexで代替） |
| ID生成 | ユーザー責任 | **ULID自動生成**（デフォルト） |
| ID型 | - | **Sendable & Hashable & Codable**（ランタイムでTupleElement検証） |
| type指定 | なし | **@Persistable(type:)** |

## 使用例

### 基本的な使用

```swift
@Persistable
struct User {
    var id: String = ULID().ulidString

    #Directory<User>("users")
    #Index<User>([\.email], unique: true)

    var email: String
    var name: String
}

// 作成（IDは自動生成済み、initに含めない）
let user = User(email: "alice@example.com", name: "Alice")
print(user.id)  // "01HXK5M3N2P4Q5R6S7T8U9V0WX"

// 関連オブジェクトも即座に作れる
let profile = Profile(userID: user.id, bio: "Hello!")

// 保存
try await store.save(user)
try await store.save(profile)

// IDで取得
let user = try await store.get(User.self, id: "01HXK5M3N2P4Q5R6S7T8U9V0WX")

// インデックスで検索
let user = try await store.findOne(User.self, where: \.email == "alice@example.com")
```

### マルチテナント

```swift
@Persistable
struct Order {
    var id: String = ULID().ulidString

    #Directory<Order>("tenants", Field(\.tenantID), "orders", layer: .partition)
    #Index<Order>([\.status])
    #Index<Order>([\.createdAt])

    var tenantID: String
    var status: OrderStatus
    var createdAt: Date
    var amount: Int
}

// 使用
let order = Order(
    tenantID: "tenant-1",
    status: .pending,
    createdAt: Date(),
    amount: 1000
)

// FDBキー構造:
// [tenants]/[tenant-1]/[orders]/R/Order/[id] = data
// [tenants]/[tenant-1]/[orders]/I/Order_status/[status]/[id] = ''
// [tenants]/[tenant-1]/[orders]/I/Order_createdAt/[createdAt]/[id] = ''
```

### テナント削除

```swift
// テナント全体を削除（データ + インデックス）
try await container.removeDirectory(path: ["tenants", "tenant-1"])
```

### 自動ID生成（idフィールド省略）

```swift
@Persistable
struct LogEntry {
    // idフィールドなし → マクロが自動追加

    #Directory<LogEntry>("logs")

    var level: String
    var message: String
    var timestamp: Date
}

// 使用
let log = LogEntry(level: "INFO", message: "Started", timestamp: Date())
print(log.id)  // 自動生成されたULID
```

### type指定（リネーム対応）

```swift
// 旧名: User → 新名: Member
@Persistable(type: "User")  // キーは "User" のまま
struct Member {
    var id: String = ULID().ulidString
    var name: String
}

// FDBキー: [R]/User/[id]（変わらない）
```

## 参考資料

- [ULID Specification](https://github.com/ulid/spec)
- [Firestore Data Model](https://firebase.google.com/docs/firestore/data-model)
- [FoundationDB Data Modeling](https://apple.github.io/foundationdb/data-modeling.html)
- [FoundationDB Atomic Operations](https://apple.github.io/foundationdb/developer-guide.html#atomic-operations)
