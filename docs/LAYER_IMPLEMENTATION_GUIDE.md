# fdb-xxxx-layer 実装ガイド

**fdb-runtime**上に独自のデータモデルレイヤーを構築するための完全ガイド

---

## 目次

1. [概要とアーキテクチャ](#1-概要とアーキテクチャ)
2. [クイックスタート（30分で始める）](#2-クイックスタート30分で始める)
3. [プロトコルリファレンス](#3-プロトコルリファレンス)
4. [実践的な完全実装例](#4-実践的な完全実装例)
5. [高度なトピック](#5-高度なトピック)
6. [付録](#6-付録)

---

## 1. 概要とアーキテクチャ

### 1.1 fdb-runtimeとは

**fdb-runtime**は、FoundationDB上でデータ永続化を実現するためのSwiftパッケージです。重要な設計原則は、**単一のFDBStoreが複数のデータモデルレイヤーを同時に扱える**ことです。

```
┌─────────────────────────────────────────────────────┐
│  Your Data Model Layer (fdb-record-layer, etc.)    │
│  - RecordStore<Record>                              │
│  - LayerConfiguration implementation                │
│  - DataAccess<Item> implementation                  │
│  - IndexMaintainer<Item> implementations            │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│  FDBRuntime (fdb-runtime package)                   │
│  - FDBStore (type-independent, operates on Data)    │
│  - FDBContainer (directory management)              │
│  - IndexManager (index state management)            │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│  FDBIndexing (protocol abstractions)                │
│  - LayerConfiguration protocol                      │
│  - DataAccess<Item> protocol                        │
│  - IndexMaintainer<Item> protocol                   │
│  - IndexKind (extensible index types)       │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│  FoundationDB (fdb-swift-bindings)                  │
│  - Database, Transaction                            │
│  - Tuple, Subspace                                  │
│  - Key-Value operations                             │
└─────────────────────────────────────────────────────┘
```

### 1.2 レイヤーとは

**レイヤー（Layer）**は、特定のデータモデルを提供する実装パッケージです。例：

| レイヤー名 | データモデル | 主な用途 |
|-----------|-------------|---------|
| **fdb-record-layer** | 構造化レコード（RDB風） | リレーショナルデータ、強い型付け |
| **fdb-document-layer** | ドキュメント（MongoDB風） | スキーマレス、JSON/BSON |
| **fdb-vector-layer** | ベクトル検索 | 埋め込み、類似検索、AI/ML |
| **fdb-graph-layer** | グラフ（Neo4j風） | ノード・エッジ、関係性クエリ |
| **fdb-timeseries-layer** | 時系列データ | メトリクス、ログ、センサーデータ |

### 1.3 なぜレイヤーを実装するのか

**既存のレイヤーが要件を満たさない場合**に、独自のレイヤーを実装します。例：

- **特殊なデータモデル**: 地理空間データ、メッセージキュー、イベントソーシング
- **カスタムインデックス**: 全文検索、Bloomフィルタ、カスタム集計
- **パフォーマンス最適化**: ドメイン特化型の最適化
- **既存システムとの統合**: 特定のシリアライゼーション形式、レガシーシステムとの互換性

### 1.4 レイヤー実装の責任範囲

レイヤーが実装すべきもの：

| コンポーネント | 説明 | 例 |
|---------------|------|-----|
| **LayerConfiguration** | レイヤー全体の設定・ファクトリ | 対応ItemType一覧、DataAccess/IndexMaintainer生成 |
| **DataAccess\<Item\>** | アイテムのフィールドアクセス・シリアライズ | `extractField()`, `serialize()`, `deserialize()` |
| **IndexMaintainer\<Item\>** | インデックス更新ロジック | `updateIndex()`, `scanItem()` |
| **ItemStore\<Item\>** | 型付きストアインターフェース | `save()`, `load()`, `query()` （ユーザー向けAPI） |
| **IndexKind実装** | カスタムインデックスタイプ（オプション） | 全文検索、地理空間、Bloomフィルタ |

レイヤーが実装**しなくてよい**もの：

- ✅ **FDBStore** - fdb-runtimeが提供（型非依存のストア）
- ✅ **IndexManager** - fdb-runtimeが提供（インデックス状態管理）
- ✅ **FDBContainer** - fdb-runtimeが提供（ディレクトリ管理）
- ✅ **トランザクション管理** - FoundationDBが提供
- ✅ **Tuple・Subspace** - fdb-swift-bindingsが提供

---

## 2. クイックスタート（30分で始める）

### 2.1 最小限のレイヤー実装

**目標**: 最もシンプルなKey-Valueレイヤーを30分で実装する

#### ステップ1: パッケージセットアップ

```bash
# 新しいSwiftパッケージを作成
mkdir fdb-kv-layer
cd fdb-kv-layer
swift package init --type library --name FDBKVLayer

# Package.swiftを編集
```

**Package.swift**:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fdb-kv-layer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FDBKVLayer", targets: ["FDBKVLayer"]),
    ],
    dependencies: [
        .package(path: "../fdb-runtime"),
    ],
    targets: [
        .target(
            name: "FDBKVLayer",
            dependencies: [
                .product(name: "FDBCore", package: "fdb-runtime"),
                .product(name: "FDBRuntime", package: "fdb-runtime"),
                .product(name: "FDBIndexing", package: "fdb-runtime"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FDBKVLayerTests",
            dependencies: ["FDBKVLayer"]
        ),
    ]
)
```

#### ステップ2: データモデル定義

**Sources/FDBKVLayer/KVItem.swift**:
```swift
import Foundation
import FDBCore

/// Key-Valueペア（最小限のデータモデル）
@Persistable
public struct KVItem {
    #PrimaryKey<KVItem>([\.key])

    public var key: String
    public var value: Data

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }
}
```

#### ステップ3: DataAccess実装

**Sources/FDBKVLayer/KVDataAccess.swift**:
```swift
import Foundation
import FoundationDB
import FDBIndexing

/// KVItemのフィールドアクセス実装
public struct KVDataAccess: DataAccess {
    public typealias Item = KVItem

    public init() {}

    // アイテムタイプ名
    public func itemType(for item: KVItem) -> String {
        return KVItem.persistableType
    }

    // フィールド抽出
    public func extractField(
        from item: KVItem,
        fieldName: String
    ) throws -> [any TupleElement] {
        switch fieldName {
        case "key":
            return [item.key]
        case "value":
            // Dataは直接TupleElementに変換できないため、Base64文字列化
            return [item.value.base64EncodedString()]
        default:
            throw DataAccessError.fieldNotFound(
                itemType: "KVItem",
                fieldName: fieldName
            )
        }
    }

    // シリアライズ（JSONエンコード）
    public func serialize(_ item: KVItem) throws -> FDB.Bytes {
        let data = try JSONEncoder().encode(item)
        return Array(data)
    }

    // デシリアライズ（JSONデコード）
    public func deserialize(_ bytes: FDB.Bytes) throws -> KVItem {
        let data = Data(bytes)
        return try JSONDecoder().decode(KVItem.self, from: data)
    }
}
```

#### ステップ4: LayerConfiguration実装

**Sources/FDBKVLayer/KVLayerConfiguration.swift**:
```swift
import Foundation
import FoundationDB
import FDBIndexing

/// KVレイヤーの設定
public struct KVLayerConfiguration: LayerConfiguration {
    public init() {}

    // サポートするItemType
    public var itemTypes: Set<String> {
        return [KVItem.persistableType]
    }

    // DataAccessファクトリ
    public func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
        guard itemType == KVItem.persistableType else {
            throw KVLayerError.unsupportedItemType(itemType)
        }

        // KVDataAccessを型消去して返す
        return KVDataAccess() as! any DataAccess<Item>
    }

    // IndexMaintainerファクトリ（KVレイヤーはインデックスなし）
    public func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        // KVレイヤーは単純なKey-Valueストアなのでインデックスをサポートしない
        throw KVLayerError.indexNotSupported
    }
}

public enum KVLayerError: Error {
    case unsupportedItemType(String)
    case indexNotSupported
}
```

#### ステップ5: 型付きストアAPI

**Sources/FDBKVLayer/KVStore.swift**:
```swift
import Foundation
import FoundationDB
import FDBRuntime

/// Key-Valueストア（ユーザー向けAPI）
public final class KVStore: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let store: FDBStore
    private let dataAccess: KVDataAccess

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) {
        self.database = database
        self.store = FDBStore(database: database, subspace: subspace)
        self.dataAccess = KVDataAccess()
    }

    // 保存
    public func set(key: String, value: Data) async throws {
        let item = KVItem(key: key, value: value)
        let serialized = try dataAccess.serialize(item)
        let primaryKey = Tuple([key])

        try await database.withTransaction { transaction in
            try await store.save(
                serialized,
                for: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    // 取得
    public func get(key: String) async throws -> Data? {
        let primaryKey = Tuple([key])

        return try await database.withTransaction { transaction in
            guard let bytes = try await store.load(
                itemType: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            ) else {
                return nil
            }

            let item = try dataAccess.deserialize(bytes)
            return item.value
        }
    }

    // 削除
    public func delete(key: String) async throws {
        let primaryKey = Tuple([key])

        try await database.withTransaction { transaction in
            try await store.delete(
                itemType: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }
}
```

#### ステップ6: 使用例

**Tests/FDBKVLayerTests/KVStoreTests.swift**:
```swift
import XCTest
import FoundationDB
@testable import FDBKVLayer

final class KVStoreTests: XCTestCase {
    var database: any DatabaseProtocol!
    var store: KVStore!

    override func setUp() async throws {
        try await FDBClient.initialize()
        database = try FDBClient.openDatabase()

        let rootSubspace = Subspace(prefix: Tuple("test_kv").pack())
        store = KVStore(database: database, subspace: rootSubspace)
    }

    func testSetAndGet() async throws {
        // 保存
        let testValue = "Hello, World!".data(using: .utf8)!
        try await store.set(key: "greeting", value: testValue)

        // 取得
        let retrieved = try await store.get(key: "greeting")
        XCTAssertEqual(retrieved, testValue)

        // 削除
        try await store.delete(key: "greeting")
        let deleted = try await store.get(key: "greeting")
        XCTAssertNil(deleted)
    }
}
```

### 2.2 ビルドと実行

```bash
# ビルド
swift build

# テスト実行（FoundationDBが必要）
swift test
```

**🎉 完成！** これで最小限のKey-Valueレイヤーが動作します。

---

## 3. プロトコルリファレンス

### 3.1 LayerConfiguration

**役割**: レイヤー全体の設定とファクトリメソッドを提供

```swift
public protocol LayerConfiguration: Sendable {
    /// サポートするItemType一覧
    var itemTypes: Set<String> { get }

    /// DataAccessインスタンスを生成
    func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item>

    /// IndexMaintainerインスタンスを生成
    func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item>
}
```

**実装ガイドライン**:

| メソッド | 説明 | 実装のポイント |
|---------|------|--------------|
| `itemTypes` | レイヤーが扱う全ItemType名 | `@Persistable`で生成される`persistableType`を使用 |
| `makeDataAccess` | ItemType別のDataAccess生成 | 型消去が必要（`as! any DataAccess<Item>`） |
| `makeIndexMaintainer` | Index種別・ItemType別のIndexMaintainer生成 | `index.kind.identifier`で分岐 |

**実装例（複数ItemTypeサポート）**:

```swift
public struct MyLayerConfiguration: LayerConfiguration {
    private let schema: Schema

    public init(schema: Schema) {
        self.schema = schema
    }

    public var itemTypes: Set<String> {
        return Set(schema.itemTypes.map(\.persistableType))
    }

    public func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
        guard let type = schema.itemType(named: itemType) else {
            throw MyLayerError.unknownItemType(itemType)
        }

        // 型別にDataAccessを生成
        switch itemType {
        case User.persistableType:
            return UserDataAccess() as! any DataAccess<Item>
        case Product.persistableType:
            return ProductDataAccess() as! any DataAccess<Item>
        default:
            throw MyLayerError.unsupportedItemType(itemType)
        }
    }

    public func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        switch index.kind.identifier {
        case "scalar":
            let kind = try index.kind.decode(ScalarIndexKind.self)
            return ScalarIndexMaintainer(index: index, subspace: subspace) as! any IndexMaintainer<Item>
        case "vector":
            let kind = try index.kind.decode(VectorIndexKind.self)
            return VectorIndexMaintainer(kind: kind, subspace: subspace) as! any IndexMaintainer<Item>
        default:
            throw MyLayerError.unsupportedIndexKind(index.kind.identifier)
        }
    }
}
```

### 3.2 DataAccess\<Item\>

**役割**: Itemのメタデータ抽出、フィールドアクセス、シリアライゼーション

```swift
public protocol DataAccess<Item>: Sendable {
    associatedtype Item: Sendable

    // メタデータ
    func itemType(for item: Item) -> String

    // フィールドアクセス
    func extractField(from item: Item, fieldName: String) throws -> [any TupleElement]

    // KeyExpression評価（デフォルト実装あり）
    func evaluate(item: Item, expression: KeyExpression) throws -> [any TupleElement]

    // シリアライゼーション
    func serialize(_ item: Item) throws -> FDB.Bytes
    func deserialize(_ bytes: FDB.Bytes) throws -> Item

    // カバリングインデックス（オプション）
    var supportsReconstruction: Bool { get }
    func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Item
}
```

**主要メソッド詳細**:

#### 3.2.1 extractField

**シグネチャ**:
```swift
func extractField(from item: Item, fieldName: String) throws -> [any TupleElement]
```

**目的**: フィールド名から値を抽出してTupleElementの配列に変換

**戻り値**: 通常は単一要素の配列（`[value]`）、複数値フィールドの場合は複数要素

**フィールド名の形式**:
- シンプルフィールド: `"email"`, `"price"`
- ネストフィールド: `"user.address.city"` （ドット記法）

**実装パターン**:

1. **リフレクションベース** (Mirror API使用):
```swift
public func extractField(from item: Item, fieldName: String) throws -> [any TupleElement] {
    let mirror = Mirror(reflecting: item)

    // ドット記法対応
    let components = fieldName.split(separator: ".")
    var current: Any = item

    for component in components {
        guard let child = Mirror(reflecting: current).children.first(where: {
            $0.label == String(component)
        }) else {
            throw DataAccessError.fieldNotFound(
                itemType: String(describing: Item.self),
                fieldName: fieldName
            )
        }
        current = child.value
    }

    // TupleElementに変換
    guard let tupleElement = current as? any TupleElement else {
        throw DataAccessError.typeMismatch(
            itemType: String(describing: Item.self),
            fieldName: fieldName,
            expected: "TupleElement",
            actual: String(describing: type(of: current))
        )
    }

    return [tupleElement]
}
```

2. **マクロ生成コードベース** (推奨、パフォーマンス最適):
```swift
// @Persistableマクロが生成するコードを利用
extension User {
    static func extractField(fieldName: String, from instance: User) -> [any TupleElement]? {
        switch fieldName {
        case "userID": return [instance.userID]
        case "email": return [instance.email]
        case "name": return [instance.name]
        default: return nil
        }
    }
}

public func extractField(from item: User, fieldName: String) throws -> [any TupleElement] {
    guard let values = User.extractField(fieldName: fieldName, from: item) else {
        throw DataAccessError.fieldNotFound(itemType: "User", fieldName: fieldName)
    }
    return values
}
```

3. **KeyPath辞書ベース**:
```swift
struct ProductDataAccess: DataAccess {
    typealias Item = Product

    private let fieldExtractors: [String: (Product) -> any TupleElement] = [
        "productID": { $0.productID },
        "name": { $0.name },
        "price": { $0.price },
        "category": { $0.category }
    ]

    public func extractField(from item: Product, fieldName: String) throws -> [any TupleElement] {
        guard let extractor = fieldExtractors[fieldName] else {
            throw DataAccessError.fieldNotFound(itemType: "Product", fieldName: fieldName)
        }
        return [extractor(item)]
    }
}
```

#### 3.2.2 evaluate (KeyExpression評価)

**デフォルト実装**: プロトコル拡張で提供されているため、通常はオーバーライド不要

```swift
// FDBIndexing/DataAccess.swift（デフォルト実装）
extension DataAccess {
    public func evaluate(
        item: Item,
        expression: KeyExpression
    ) throws -> [any TupleElement] {
        let visitor = DataAccessEvaluator(dataAccess: self, item: item)
        return try expression.accept(visitor: visitor)
    }
}
```

**Visitor実装**:
```swift
private struct DataAccessEvaluator<Access: DataAccess>: KeyExpressionVisitor {
    let dataAccess: Access
    let item: Access.Item

    typealias Result = [any TupleElement]

    func visitField(_ fieldName: String) throws -> [any TupleElement] {
        return try dataAccess.extractField(from: item, fieldName: fieldName)
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws -> [any TupleElement] {
        var result: [any TupleElement] = []
        for expression in expressions {
            let values = try expression.accept(visitor: self)
            result.append(contentsOf: values)
        }
        return result
    }

    func visitLiteral(_ value: any TupleElement) throws -> [any TupleElement] {
        return [value]
    }

    // ... 他のvisitメソッド
}
```

**使用例**:
```swift
let user = User(userID: 123, email: "alice@example.com", name: "Alice")
let dataAccess = UserDataAccess()

// 単一フィールド
let expr1 = FieldKeyExpression("email")
let values1 = try dataAccess.evaluate(item: user, expression: expr1)
// Result: ["alice@example.com"]

// 複合キー
let expr2 = ConcatenateKeyExpression([
    FieldKeyExpression("country"),
    FieldKeyExpression("userID")
])
let values2 = try dataAccess.evaluate(item: user, expression: expr2)
// Result: ["US", 123]
```

#### 3.2.3 serialize / deserialize

**シグネチャ**:
```swift
func serialize(_ item: Item) throws -> FDB.Bytes
func deserialize(_ bytes: FDB.Bytes) throws -> Item
```

**実装パターン**:

1. **JSON** (シンプル、デバッグしやすい):
```swift
public func serialize(_ item: Item) throws -> FDB.Bytes {
    let data = try JSONEncoder().encode(item)
    return Array(data)
}

public func deserialize(_ bytes: FDB.Bytes) throws -> Item {
    let data = Data(bytes)
    return try JSONDecoder().decode(Item.self, from: data)
}
```

2. **Protobuf** (コンパクト、パフォーマンス最適):
```swift
import SwiftProtobuf

public func serialize(_ item: Item) throws -> FDB.Bytes {
    let proto = item.toProto()  // 変換ロジック
    return try Array(proto.serializedData())
}

public func deserialize(_ bytes: FDB.Bytes) throws -> Item {
    let proto = try MyProto(serializedData: Data(bytes))
    return Item(from: proto)  // 変換ロジック
}
```

3. **MessagePack** (バイナリ、JSONより軽量):
```swift
import MessagePacker

public func serialize(_ item: Item) throws -> FDB.Bytes {
    return try MessagePackEncoder().encode(item)
}

public func deserialize(_ bytes: FDB.Bytes) throws -> Item {
    return try MessagePackDecoder().decode(Item.self, from: Data(bytes))
}
```

**選択ガイドライン**:

| フォーマット | メリット | デメリット | 推奨ケース |
|------------|---------|----------|-----------|
| JSON | デバッグ容易、互換性高い | サイズ大、遅い | 開発初期、小規模データ |
| Protobuf | 高速、コンパクト | スキーマ定義必要 | 本番環境、大規模データ |
| MessagePack | JSONより軽量、スキーマレス | Protobufより遅い | 中規模データ、柔軟性重視 |

### 3.3 IndexMaintainer\<Item\>

**役割**: インデックスの更新・構築ロジック

```swift
public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Sendable

    /// アイテム変更時のインデックス更新
    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws

    /// バッチインデックス構築時のスキャン
    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws
}
```

#### 3.3.1 updateIndex

**呼び出しタイミング**:
- Insert: `updateIndex(oldItem: nil, newItem: item, ...)`
- Update: `updateIndex(oldItem: old, newItem: new, ...)`
- Delete: `updateIndex(oldItem: item, newItem: nil, ...)`

**実装パターン（Scalar Index）**:

```swift
struct ScalarIndexMaintainer<Item: Sendable>: IndexMaintainer {
    let index: Index
    let subspace: Subspace

    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws {
        // 1. 古いエントリを削除
        if let old = oldItem {
            let oldValues = try dataAccess.evaluate(item: old, expression: index.rootExpression)
            let oldPK = try dataAccess.extractPrimaryKey(from: old, using: index.primaryKeyExpression)

            var keyTuple = Tuple(oldValues)
            keyTuple.append(contentsOf: oldPK.elements)

            let key = subspace.pack(keyTuple)
            transaction.clear(key: key)
        }

        // 2. 新しいエントリを追加
        if let new = newItem {
            let newValues = try dataAccess.evaluate(item: new, expression: index.rootExpression)
            let newPK = try dataAccess.extractPrimaryKey(from: new, using: index.primaryKeyExpression)

            var keyTuple = Tuple(newValues)
            keyTuple.append(contentsOf: newPK.elements)

            let key = subspace.pack(keyTuple)
            transaction.setValue([], for: key)  // 空の値
        }
    }

    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws {
        // scanItemはupdateIndexのnewItemのみ版
        try await updateIndex(
            oldItem: nil,
            newItem: item,
            dataAccess: dataAccess,
            transaction: transaction
        )
    }
}
```

**インデックスキー構造**:
```
[indexSubspace][rootExpression values...][primary key values...] = ''
```

例:
```swift
// User by email index
// [I]/user_by_email/["alice@example.com"]/[123] = ''
//  ^     ^              ^                   ^
//  |     |              |                   |
//  |     |              |                   +-- Primary key (userID)
//  |     |              +-- rootExpression value (email)
//  |     +-- Index name
//  +-- Index subspace prefix
```

#### 3.3.2 Unique制約の実装

```swift
func updateIndex(
    oldItem: Item?,
    newItem: Item?,
    dataAccess: any DataAccess<Item>,
    transaction: any TransactionProtocol
) async throws {
    // 1. 新しいエントリをチェック（Unique制約）
    if let new = newItem {
        let newValues = try dataAccess.evaluate(item: new, expression: index.rootExpression)
        let newPK = try dataAccess.extractPrimaryKey(from: new, using: index.primaryKeyExpression)

        // Unique制約: 同じ値で異なるPKがあればエラー
        if index.options.unique {
            let prefix = subspace.pack(Tuple(newValues))
            let (begin, end) = Subspace(prefix: prefix).range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end),
                snapshot: false
            )

            for try await (existingKey, _) in sequence {
                let existingTuple = try subspace.unpack(existingKey)
                let existingPK = Tuple(Array(existingTuple.elements.dropFirst(newValues.count)))

                // 異なるPKが存在する = 制約違反
                if existingPK != newPK {
                    throw IndexError.uniqueConstraintViolation(
                        index: index.name,
                        value: newValues.description
                    )
                }
            }
        }

        // エントリ追加
        var keyTuple = Tuple(newValues)
        keyTuple.append(contentsOf: newPK.elements)
        let key = subspace.pack(keyTuple)
        transaction.setValue([], for: key)
    }

    // 2. 古いエントリを削除
    if let old = oldItem {
        let oldValues = try dataAccess.evaluate(item: old, expression: index.rootExpression)
        let oldPK = try dataAccess.extractPrimaryKey(from: old, using: index.primaryKeyExpression)

        var keyTuple = Tuple(oldValues)
        keyTuple.append(contentsOf: oldPK.elements)
        let key = subspace.pack(keyTuple)
        transaction.clear(key: key)
    }
}
```

### 3.4 IndexKind（カスタムインデックスタイプ）

**役割**: 新しいインデックスタイプを定義

```swift
public protocol IndexKind: Sendable, Codable, Hashable {
    /// 識別子（例: "scalar", "vector", "com.mycompany.bloom"）
    static var identifier: String { get }

    /// サブスペース構造タイプ
    static var subspaceStructure: SubspaceStructure { get }

    /// フィールドタイプの検証
    static func validateTypes(_ types: [Any.Type]) throws
}

public enum SubspaceStructure: String, Sendable, Codable {
    case flat          // フラット: [value][pk] = ''
    case hierarchical  // 階層: HNSWグラフなど
    case aggregation   // 集計: COUNT, SUMを直接格納
}
```

**実装例（Bloomフィルタインデックス）**:

```swift
/// Bloomフィルタインデックス（存在確認の高速化）
public struct BloomFilterIndexKind: IndexKind {
    public static let identifier = "bloom_filter"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public let expectedElements: Int
    public let falsePositiveRate: Double

    public init(
        expectedElements: Int = 10_000,
        falsePositiveRate: Double = 0.01
    ) {
        self.expectedElements = expectedElements
        self.falsePositiveRate = falsePositiveRate
    }

    public static func validateTypes(_ types: [Any.Type]) throws {
        // 単一フィールドのみサポート
        guard types.count == 1 else {
            throw IndexKindError.invalidFieldCount(
                kind: identifier,
                expected: 1,
                actual: types.count
            )
        }

        // Hashableな型のみサポート
        guard types[0] is any Hashable.Type else {
            throw IndexKindError.typeNotSupported(
                kind: identifier,
                type: String(describing: types[0]),
                reason: "Bloom filter requires Hashable types"
            )
        }
    }
}
```

**使用例**:
```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>(
        [\.email],
        type: BloomFilterIndexKind(
            expectedElements: 1_000_000,
            falsePositiveRate: 0.001
        )
    )

    var userID: Int64
    var email: String
}
```

---

## 4. 実践的な完全実装例

### 4.1 SimpleKVLayer（完全版）

前述のクイックスタートを拡張し、トランザクション、範囲クエリ、エラーハンドリングを追加。

**Sources/FDBKVLayer/KVStore.swift（完全版）**:

```swift
import Foundation
import FoundationDB
import FDBRuntime
import Logging

public final class KVStore: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let store: FDBStore
    private let dataAccess: KVDataAccess
    private let logger: Logger

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        logger: Logger = Logger(label: "com.example.kvstore")
    ) {
        self.database = database
        self.store = FDBStore(database: database, subspace: subspace)
        self.dataAccess = KVDataAccess()
        self.logger = logger
    }

    // MARK: - 単一キー操作

    /// 値を設定
    public func set(key: String, value: Data, transaction: (any TransactionProtocol)? = nil) async throws {
        let item = KVItem(key: key, value: value)
        let serialized = try dataAccess.serialize(item)
        let primaryKey = Tuple([key])

        if let transaction = transaction {
            // トランザクション内
            try await store.save(
                serialized,
                for: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        } else {
            // 新規トランザクション
            try await database.withTransaction { transaction in
                try await store.save(
                    serialized,
                    for: KVItem.persistableType,
                    primaryKey: primaryKey,
                    transaction: transaction
                )
            }
        }

        logger.info("Set key", metadata: ["key": .string(key)])
    }

    /// 値を取得
    public func get(key: String, transaction: (any TransactionProtocol)? = nil) async throws -> Data? {
        let primaryKey = Tuple([key])

        let bytes: FDB.Bytes?
        if let transaction = transaction {
            bytes = try await store.load(
                itemType: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        } else {
            bytes = try await database.withTransaction { transaction in
                try await store.load(
                    itemType: KVItem.persistableType,
                    primaryKey: primaryKey,
                    transaction: transaction
                )
            }
        }

        guard let bytes = bytes else {
            logger.debug("Key not found", metadata: ["key": .string(key)])
            return nil
        }

        let item = try dataAccess.deserialize(bytes)
        return item.value
    }

    /// 値を削除
    public func delete(key: String, transaction: (any TransactionProtocol)? = nil) async throws {
        let primaryKey = Tuple([key])

        if let transaction = transaction {
            try await store.delete(
                itemType: KVItem.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        } else {
            try await database.withTransaction { transaction in
                try await store.delete(
                    itemType: KVItem.persistableType,
                    primaryKey: primaryKey,
                    transaction: transaction
                )
            }
        }

        logger.info("Deleted key", metadata: ["key": .string(key)])
    }

    // MARK: - 範囲クエリ

    /// プレフィックスでスキャン
    public func scan(
        prefix: String,
        limit: Int? = nil
    ) async throws -> [(key: String, value: Data)] {
        return try await database.withTransaction { transaction in
            try await self.scan(prefix: prefix, limit: limit, transaction: transaction)
        }
    }

    /// プレフィックスでスキャン（トランザクション内）
    public func scan(
        prefix: String,
        limit: Int? = nil,
        transaction: any TransactionProtocol
    ) async throws -> [(key: String, value: Data)] {
        var results: [(key: String, value: Data)] = []

        let itemSubspace = store.itemSubspace(for: KVItem.persistableType)
        let prefixTuple = Tuple([prefix])
        let prefixKey = itemSubspace.pack(prefixTuple)

        // プレフィックス範囲を計算
        let begin = prefixKey
        var end = prefixKey
        end.append(0xFF)  // プレフィックス範囲の終端

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            snapshot: true
        )

        var count = 0
        for try await (_, valueBytes) in sequence {
            let item = try dataAccess.deserialize(valueBytes)
            results.append((key: item.key, value: item.value))

            count += 1
            if let limit = limit, count >= limit {
                break
            }
        }

        logger.info("Scanned keys", metadata: [
            "prefix": .string(prefix),
            "count": .stringConvertible(results.count)
        ])

        return results
    }

    // MARK: - バッチ操作

    /// 複数キーを一括設定
    public func setMany(_ items: [(key: String, value: Data)]) async throws {
        try await database.withTransaction { transaction in
            for (key, value) in items {
                try await self.set(key: key, value: value, transaction: transaction)
            }
        }
    }

    /// 複数キーを一括取得
    public func getMany(_ keys: [String]) async throws -> [String: Data] {
        try await database.withTransaction { transaction in
            var results: [String: Data] = [:]

            for key in keys {
                if let value = try await self.get(key: key, transaction: transaction) {
                    results[key] = value
                }
            }

            return results
        }
    }

    // MARK: - トランザクション

    /// トランザクション実行
    public func withTransaction<T>(
        _ block: @Sendable (any TransactionProtocol, KVStore) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction { transaction in
            try await block(transaction, self)
        }
    }
}
```

**使用例**:

```swift
let store = KVStore(database: database, subspace: rootSubspace)

// 単一操作
try await store.set(key: "user:123", value: userData)
let value = try await store.get(key: "user:123")
try await store.delete(key: "user:123")

// バッチ操作
try await store.setMany([
    ("user:1", user1Data),
    ("user:2", user2Data),
    ("user:3", user3Data)
])

let users = try await store.getMany(["user:1", "user:2", "user:3"])

// 範囲クエリ
let allUsers = try await store.scan(prefix: "user:", limit: 100)

// トランザクション
try await store.withTransaction { transaction, store in
    // Atomic read-modify-write
    guard let data = try await store.get(key: "counter", transaction: transaction) else {
        try await store.set(key: "counter", value: Data([0, 0, 0, 0]), transaction: transaction)
        return
    }

    var counter = data.withUnsafeBytes { $0.load(as: Int32.self) }
    counter += 1

    let newData = withUnsafeBytes(of: counter) { Data($0) }
    try await store.set(key: "counter", value: newData, transaction: transaction)
}
```

### 4.2 GraphLayer（ノード・エッジモデル）

グラフデータベース風のレイヤー実装。

#### データモデル

**Sources/FDBGraphLayer/Node.swift**:
```swift
import Foundation
import FDBCore

@Persistable
public struct Node {
    #PrimaryKey<Node>([\.nodeID])
    #Index<Node>([\.label], type: ScalarIndexKind())

    public var nodeID: String
    public var label: String
    public var properties: [String: PropertyValue]

    public init(nodeID: String, label: String, properties: [String: PropertyValue] = [:]) {
        self.nodeID = nodeID
        self.label = label
        self.properties = properties
    }
}

@Persistable
public struct Edge {
    #PrimaryKey<Edge>([\.edgeID])
    #Index<Edge>([\.fromNodeID, \.label], type: ScalarIndexKind())
    #Index<Edge>([\.toNodeID, \.label], type: ScalarIndexKind())

    public var edgeID: String
    public var label: String
    public var fromNodeID: String
    public var toNodeID: String
    public var properties: [String: PropertyValue]

    public init(
        edgeID: String,
        label: String,
        fromNodeID: String,
        toNodeID: String,
        properties: [String: PropertyValue] = [:]
    ) {
        self.edgeID = edgeID
        self.label = label
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.properties = properties
    }
}

public enum PropertyValue: Codable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
}
```

#### GraphStore API

**Sources/FDBGraphLayer/GraphStore.swift**:
```swift
import Foundation
import FoundationDB
import FDBRuntime

public final class GraphStore: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let store: FDBStore
    private let nodeAccess: NodeDataAccess
    private let edgeAccess: EdgeDataAccess

    public init(database: any DatabaseProtocol, subspace: Subspace) {
        self.database = database
        self.store = FDBStore(database: database, subspace: subspace)
        self.nodeAccess = NodeDataAccess()
        self.edgeAccess = EdgeDataAccess()
    }

    // MARK: - Node操作

    public func createNode(_ node: Node) async throws {
        let serialized = try nodeAccess.serialize(node)
        let primaryKey = Tuple([node.nodeID])

        try await database.withTransaction { transaction in
            try await store.save(
                serialized,
                for: Node.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    public func getNode(nodeID: String) async throws -> Node? {
        let primaryKey = Tuple([nodeID])

        return try await database.withTransaction { transaction in
            guard let bytes = try await store.load(
                itemType: Node.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            ) else {
                return nil
            }

            return try nodeAccess.deserialize(bytes)
        }
    }

    public func deleteNode(nodeID: String) async throws {
        let primaryKey = Tuple([nodeID])

        try await database.withTransaction { transaction in
            // 関連エッジも削除
            let outgoingEdges = try await self.getOutgoingEdges(
                fromNodeID: nodeID,
                transaction: transaction
            )
            let incomingEdges = try await self.getIncomingEdges(
                toNodeID: nodeID,
                transaction: transaction
            )

            for edge in outgoingEdges + incomingEdges {
                let edgePK = Tuple([edge.edgeID])
                try await store.delete(
                    itemType: Edge.persistableType,
                    primaryKey: edgePK,
                    transaction: transaction
                )
            }

            // ノード削除
            try await store.delete(
                itemType: Node.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    // MARK: - Edge操作

    public func createEdge(_ edge: Edge) async throws {
        let serialized = try edgeAccess.serialize(edge)
        let primaryKey = Tuple([edge.edgeID])

        try await database.withTransaction { transaction in
            // ノード存在確認
            guard try await self.getNode(nodeID: edge.fromNodeID) != nil,
                  try await self.getNode(nodeID: edge.toNodeID) != nil else {
                throw GraphError.nodeNotFound
            }

            try await store.save(
                serialized,
                for: Edge.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    public func getEdge(edgeID: String) async throws -> Edge? {
        let primaryKey = Tuple([edgeID])

        return try await database.withTransaction { transaction in
            guard let bytes = try await store.load(
                itemType: Edge.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            ) else {
                return nil
            }

            return try edgeAccess.deserialize(bytes)
        }
    }

    // MARK: - グラフトラバーサル

    public func getOutgoingEdges(
        fromNodeID: String,
        label: String? = nil
    ) async throws -> [Edge] {
        return try await database.withTransaction { transaction in
            try await self.getOutgoingEdges(
                fromNodeID: fromNodeID,
                label: label,
                transaction: transaction
            )
        }
    }

    private func getOutgoingEdges(
        fromNodeID: String,
        label: String?,
        transaction: any TransactionProtocol
    ) async throws -> [Edge] {
        // Index: [I]/Edge_fromNodeID_label/[fromNodeID]/[label]/[edgeID]
        let indexSubspace = store.indexSubspace(for: "Edge_fromNodeID_label")

        let prefix: Tuple
        if let label = label {
            prefix = Tuple([fromNodeID, label])
        } else {
            prefix = Tuple([fromNodeID])
        }

        let prefixKey = indexSubspace.pack(prefix)
        var endKey = prefixKey
        endKey.append(0xFF)

        var edges: [Edge] = []

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(prefixKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        for try await (key, _) in sequence {
            let tuple = try indexSubspace.unpack(key)
            let edgeID = tuple.elements.last as! String

            if let edge = try await self.getEdge(edgeID: edgeID) {
                edges.append(edge)
            }
        }

        return edges
    }

    public func getIncomingEdges(
        toNodeID: String,
        label: String? = nil
    ) async throws -> [Edge] {
        return try await database.withTransaction { transaction in
            try await self.getIncomingEdges(
                toNodeID: toNodeID,
                label: label,
                transaction: transaction
            )
        }
    }

    private func getIncomingEdges(
        toNodeID: String,
        label: String?,
        transaction: any TransactionProtocol
    ) async throws -> [Edge] {
        // Index: [I]/Edge_toNodeID_label/[toNodeID]/[label]/[edgeID]
        let indexSubspace = store.indexSubspace(for: "Edge_toNodeID_label")

        let prefix: Tuple
        if let label = label {
            prefix = Tuple([toNodeID, label])
        } else {
            prefix = Tuple([toNodeID])
        }

        let prefixKey = indexSubspace.pack(prefix)
        var endKey = prefixKey
        endKey.append(0xFF)

        var edges: [Edge] = []

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(prefixKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        for try await (key, _) in sequence {
            let tuple = try indexSubspace.unpack(key)
            let edgeID = tuple.elements.last as! String

            if let edge = try await self.getEdge(edgeID: edgeID) {
                edges.append(edge)
            }
        }

        return edges
    }

    // MARK: - グラフクエリ

    /// 1-hopネイバーを取得
    public func getNeighbors(
        nodeID: String,
        edgeLabel: String? = nil
    ) async throws -> [Node] {
        let outgoingEdges = try await getOutgoingEdges(fromNodeID: nodeID, label: edgeLabel)

        var neighbors: [Node] = []
        for edge in outgoingEdges {
            if let node = try await getNode(nodeID: edge.toNodeID) {
                neighbors.append(node)
            }
        }

        return neighbors
    }

    /// 2-hopネイバーを取得
    public func getTwoHopNeighbors(
        nodeID: String,
        edgeLabel: String? = nil
    ) async throws -> [Node] {
        let oneHop = try await getNeighbors(nodeID: nodeID, edgeLabel: edgeLabel)

        var twoHopSet: Set<String> = []
        for neighbor in oneHop {
            let secondHop = try await getNeighbors(nodeID: neighbor.nodeID, edgeLabel: edgeLabel)
            for node in secondHop {
                if node.nodeID != nodeID {  // 元のノードを除外
                    twoHopSet.insert(node.nodeID)
                }
            }
        }

        var results: [Node] = []
        for nodeID in twoHopSet {
            if let node = try await getNode(nodeID: nodeID) {
                results.append(node)
            }
        }

        return results
    }
}

public enum GraphError: Error {
    case nodeNotFound
    case edgeNotFound
    case invalidOperation(String)
}
```

**使用例**:
```swift
let graphStore = GraphStore(database: database, subspace: graphSubspace)

// ノード作成
let alice = Node(nodeID: "alice", label: "User", properties: [
    "name": .string("Alice"),
    "age": .int(30)
])
let bob = Node(nodeID: "bob", label: "User", properties: [
    "name": .string("Bob"),
    "age": .int(25)
])

try await graphStore.createNode(alice)
try await graphStore.createNode(bob)

// エッジ作成
let follows = Edge(
    edgeID: "alice_follows_bob",
    label: "FOLLOWS",
    fromNodeID: "alice",
    toNodeID: "bob",
    properties: ["since": .string("2024-01-01")]
)

try await graphStore.createEdge(follows)

// グラフクエリ
let neighbors = try await graphStore.getNeighbors(nodeID: "alice", edgeLabel: "FOLLOWS")
// Result: [bob]

let outgoing = try await graphStore.getOutgoingEdges(fromNodeID: "alice")
// Result: [follows]
```

### 4.3 TimeSeriesLayer（時系列データ）

時系列データに最適化されたレイヤー。

#### データモデル

**Sources/FDBTimeSeriesLayer/Metric.swift**:
```swift
import Foundation
import FDBCore

@Persistable
public struct Metric {
    #PrimaryKey<Metric>([\.metricName, \.timestamp])

    public var metricName: String
    public var timestamp: Int64  // Unix timestamp (ミリ秒)
    public var value: Double
    public var tags: [String: String]

    public init(
        metricName: String,
        timestamp: Int64,
        value: Double,
        tags: [String: String] = [:]
    ) {
        self.metricName = metricName
        self.timestamp = timestamp
        self.value = value
        self.tags = tags
    }
}
```

#### TimeSeriesStore API

**Sources/FDBTimeSeriesLayer/TimeSeriesStore.swift**:
```swift
import Foundation
import FoundationDB
import FDBRuntime

public final class TimeSeriesStore: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let store: FDBStore
    private let dataAccess: MetricDataAccess

    public init(database: any DatabaseProtocol, subspace: Subspace) {
        self.database = database
        self.store = FDBStore(database: database, subspace: subspace)
        self.dataAccess = MetricDataAccess()
    }

    // MARK: - Write操作

    /// メトリックを書き込み
    public func write(_ metric: Metric) async throws {
        let serialized = try dataAccess.serialize(metric)
        let primaryKey = Tuple([metric.metricName, metric.timestamp])

        try await database.withTransaction { transaction in
            try await store.save(
                serialized,
                for: Metric.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    /// 複数メトリックをバッチ書き込み
    public func writeBatch(_ metrics: [Metric]) async throws {
        try await database.withTransaction { transaction in
            for metric in metrics {
                let serialized = try dataAccess.serialize(metric)
                let primaryKey = Tuple([metric.metricName, metric.timestamp])

                try await store.save(
                    serialized,
                    for: Metric.persistableType,
                    primaryKey: primaryKey,
                    transaction: transaction
                )
            }
        }
    }

    // MARK: - Query操作

    /// 時間範囲でメトリックを取得
    public func query(
        metricName: String,
        startTime: Int64,
        endTime: Int64,
        limit: Int? = nil
    ) async throws -> [Metric] {
        return try await database.withTransaction { transaction in
            try await self.query(
                metricName: metricName,
                startTime: startTime,
                endTime: endTime,
                limit: limit,
                transaction: transaction
            )
        }
    }

    private func query(
        metricName: String,
        startTime: Int64,
        endTime: Int64,
        limit: Int?,
        transaction: any TransactionProtocol
    ) async throws -> [Metric] {
        let itemSubspace = store.itemSubspace(for: Metric.persistableType)

        let beginKey = itemSubspace.pack(Tuple([metricName, startTime]))
        let endKey = itemSubspace.pack(Tuple([metricName, endTime]))

        var metrics: [Metric] = []

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        var count = 0
        for try await (_, valueBytes) in sequence {
            let metric = try dataAccess.deserialize(valueBytes)
            metrics.append(metric)

            count += 1
            if let limit = limit, count >= limit {
                break
            }
        }

        return metrics
    }

    // MARK: - 集計操作

    /// 平均値を計算
    public func average(
        metricName: String,
        startTime: Int64,
        endTime: Int64
    ) async throws -> Double? {
        let metrics = try await query(
            metricName: metricName,
            startTime: startTime,
            endTime: endTime
        )

        guard !metrics.isEmpty else { return nil }

        let sum = metrics.reduce(0.0) { $0 + $1.value }
        return sum / Double(metrics.count)
    }

    /// 最大値を計算
    public func max(
        metricName: String,
        startTime: Int64,
        endTime: Int64
    ) async throws -> Double? {
        let metrics = try await query(
            metricName: metricName,
            startTime: startTime,
            endTime: endTime
        )

        return metrics.map(\.value).max()
    }

    /// 最小値を計算
    public func min(
        metricName: String,
        startTime: Int64,
        endTime: Int64
    ) async throws -> Double? {
        let metrics = try await query(
            metricName: metricName,
            startTime: startTime,
            endTime: endTime
        )

        return metrics.map(\.value).min()
    }

    /// ダウンサンプリング（時間バケット集計）
    public func downsample(
        metricName: String,
        startTime: Int64,
        endTime: Int64,
        bucketSize: Int64,  // ミリ秒単位
        aggregation: AggregationType = .average
    ) async throws -> [(timestamp: Int64, value: Double)] {
        let metrics = try await query(
            metricName: metricName,
            startTime: startTime,
            endTime: endTime
        )

        var buckets: [Int64: [Double]] = [:]

        for metric in metrics {
            let bucketStart = (metric.timestamp / bucketSize) * bucketSize
            buckets[bucketStart, default: []].append(metric.value)
        }

        var results: [(timestamp: Int64, value: Double)] = []

        for (timestamp, values) in buckets.sorted(by: { $0.key < $1.key }) {
            let aggregatedValue: Double

            switch aggregation {
            case .average:
                aggregatedValue = values.reduce(0.0, +) / Double(values.count)
            case .max:
                aggregatedValue = values.max() ?? 0.0
            case .min:
                aggregatedValue = values.min() ?? 0.0
            case .sum:
                aggregatedValue = values.reduce(0.0, +)
            }

            results.append((timestamp: timestamp, value: aggregatedValue))
        }

        return results
    }

    // MARK: - データ保持ポリシー

    /// 古いデータを削除（保持期間を超えたデータ）
    public func deleteOldData(
        metricName: String,
        retentionPeriod: TimeInterval  // 秒単位
    ) async throws -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffTime = now - Int64(retentionPeriod * 1000)

        return try await database.withTransaction { transaction in
            let itemSubspace = store.itemSubspace(for: Metric.persistableType)

            let beginKey = itemSubspace.pack(Tuple([metricName, Int64.min]))
            let endKey = itemSubspace.pack(Tuple([metricName, cutoffTime]))

            var count = 0

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: false
            )

            for try await (key, _) in sequence {
                transaction.clear(key: key)
                count += 1
            }

            return count
        }
    }
}

public enum AggregationType {
    case average
    case max
    case min
    case sum
}
```

**使用例**:
```swift
let tsStore = TimeSeriesStore(database: database, subspace: tsSubspace)

// メトリック書き込み
let now = Int64(Date().timeIntervalSince1970 * 1000)

try await tsStore.write(Metric(
    metricName: "cpu.usage",
    timestamp: now,
    value: 45.2,
    tags: ["host": "server-01", "region": "us-west"]
))

// バッチ書き込み
let metrics = (0..<100).map { i in
    Metric(
        metricName: "cpu.usage",
        timestamp: now + Int64(i * 1000),  // 1秒間隔
        value: Double.random(in: 0...100),
        tags: ["host": "server-01"]
    )
}
try await tsStore.writeBatch(metrics)

// クエリ
let oneHourAgo = now - 3600_000
let recentMetrics = try await tsStore.query(
    metricName: "cpu.usage",
    startTime: oneHourAgo,
    endTime: now,
    limit: 1000
)

// 集計
let avgCPU = try await tsStore.average(
    metricName: "cpu.usage",
    startTime: oneHourAgo,
    endTime: now
)

// ダウンサンプリング（5分バケット）
let downsampled = try await tsStore.downsample(
    metricName: "cpu.usage",
    startTime: oneHourAgo,
    endTime: now,
    bucketSize: 300_000,  // 5分 = 300秒 = 300,000ミリ秒
    aggregation: .average
)

// 古いデータ削除（30日以上前）
let deleted = try await tsStore.deleteOldData(
    metricName: "cpu.usage",
    retentionPeriod: 30 * 24 * 3600  // 30日
)
print("Deleted \(deleted) old metrics")
```

### 4.4 カスタムIndexKind実装例

#### 全文検索インデックス

**Sources/FDBSearchLayer/FullTextIndexKind.swift**:
```swift
import Foundation
import FDBIndexing

/// 全文検索インデックス
public struct FullTextIndexKind: IndexKind {
    public static let identifier = "fulltext"
    public static let subspaceStructure = SubspaceStructure.hierarchical

    public let analyzer: TextAnalyzer
    public let minWordLength: Int
    public let stopWords: Set<String>

    public init(
        analyzer: TextAnalyzer = .standard,
        minWordLength: Int = 2,
        stopWords: Set<String> = []
    ) {
        self.analyzer = analyzer
        self.minWordLength = minWordLength
        self.stopWords = stopWords
    }

    public static func validateTypes(_ types: [Any.Type]) throws {
        // 単一Stringフィールドのみサポート
        guard types.count == 1, types[0] == String.self else {
            throw IndexKindError.typeNotSupported(
                kind: identifier,
                type: types.map { String(describing: $0) }.joined(separator: ", "),
                reason: "Full-text index requires a single String field"
            )
        }
    }
}

public enum TextAnalyzer: String, Sendable, Codable, Hashable {
    case standard    // 空白分割、小文字化
    case ngram       // N-gram分割
    case japanese    // 形態素解析（MeCab想定）
}
```

**IndexMaintainer実装**:

```swift
import Foundation
import FoundationDB
import FDBIndexing

struct FullTextIndexMaintainer<Item: Sendable>: IndexMaintainer {
    let index: Index
    let subspace: Subspace
    let kind: FullTextIndexKind

    init(index: Index, subspace: Subspace, kind: FullTextIndexKind) {
        self.index = index
        self.subspace = subspace
        self.kind = kind
    }

    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws {
        let primaryKey = try dataAccess.extractPrimaryKey(
            from: newItem ?? oldItem!,
            using: index.primaryKeyExpression
        )

        // 1. 古いエントリを削除
        if let old = oldItem {
            let oldValues = try dataAccess.evaluate(item: old, expression: index.rootExpression)
            guard let oldText = oldValues.first as? String else {
                throw FullTextError.invalidFieldType
            }

            let oldTokens = tokenize(oldText)
            for token in oldTokens {
                let key = subspace.pack(Tuple([token]).appending(contentsOf: primaryKey.elements))
                transaction.clear(key: key)
            }
        }

        // 2. 新しいエントリを追加
        if let new = newItem {
            let newValues = try dataAccess.evaluate(item: new, expression: index.rootExpression)
            guard let newText = newValues.first as? String else {
                throw FullTextError.invalidFieldType
            }

            let newTokens = tokenize(newText)
            for token in newTokens {
                let key = subspace.pack(Tuple([token]).appending(contentsOf: primaryKey.elements))
                transaction.setValue([], for: key)
            }
        }
    }

    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws {
        try await updateIndex(
            oldItem: nil,
            newItem: item,
            dataAccess: dataAccess,
            transaction: transaction
        )
    }

    // MARK: - トークナイズ

    private func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []

        switch kind.analyzer {
        case .standard:
            // 空白分割 + 小文字化
            let words = text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count >= kind.minWordLength }
                .filter { !kind.stopWords.contains($0) }

            tokens.formUnion(words)

        case .ngram:
            // 2-gram（バイグラム）
            let lowercased = text.lowercased()
            for i in 0..<(lowercased.count - 1) {
                let start = lowercased.index(lowercased.startIndex, offsetBy: i)
                let end = lowercased.index(start, offsetBy: 2)
                let bigram = String(lowercased[start..<end])
                tokens.insert(bigram)
            }

        case .japanese:
            // TODO: MeCab統合（形態素解析）
            // 簡易実装: 文字単位のN-gram
            let words = text.components(separatedBy: .whitespacesAndNewlines)
            for word in words {
                for i in 0..<(word.count - 1) {
                    let start = word.index(word.startIndex, offsetBy: i)
                    let end = word.index(start, offsetBy: 2)
                    let bigram = String(word[start..<end])
                    tokens.insert(bigram)
                }
            }
        }

        return tokens
    }
}

enum FullTextError: Error {
    case invalidFieldType
}
```

**検索クエリAPI**:

```swift
extension FDBStore {
    /// 全文検索
    public func searchFullText(
        indexName: String,
        query: String,
        limit: Int = 100
    ) async throws -> [Tuple] {
        return try await database.withTransaction { transaction in
            try await self.searchFullText(
                indexName: indexName,
                query: query,
                limit: limit,
                transaction: transaction
            )
        }
    }

    public func searchFullText(
        indexName: String,
        query: String,
        limit: Int,
        transaction: any TransactionProtocol
    ) async throws -> [Tuple] {
        let indexSubspace = self.indexSubspace(for: indexName)

        // クエリをトークナイズ（同じAnalyzerを使用）
        let tokens = tokenize(query, analyzer: .standard)

        guard let firstToken = tokens.first else {
            return []
        }

        // 最初のトークンで候補を取得
        var candidates: Set<Tuple> = []

        let prefixKey = indexSubspace.pack(Tuple([firstToken]))
        var endKey = prefixKey
        endKey.append(0xFF)

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(prefixKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        for try await (key, _) in sequence {
            let tuple = try indexSubspace.unpack(key)
            // [token, pk1, pk2, ...] → [pk1, pk2, ...]
            let primaryKey = Tuple(Array(tuple.elements.dropFirst()))
            candidates.insert(primaryKey)
        }

        // 他のトークンでフィルタリング（AND検索）
        for token in tokens.dropFirst() {
            let prefixKey = indexSubspace.pack(Tuple([token]))
            var endKey = prefixKey
            endKey.append(0xFF)

            var tokenMatches: Set<Tuple> = []

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(prefixKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            for try await (key, _) in sequence {
                let tuple = try indexSubspace.unpack(key)
                let primaryKey = Tuple(Array(tuple.elements.dropFirst()))
                tokenMatches.insert(primaryKey)
            }

            candidates.formIntersection(tokenMatches)
        }

        return Array(candidates.prefix(limit))
    }

    private func tokenize(_ text: String, analyzer: TextAnalyzer) -> Set<String> {
        // FullTextIndexMaintainerと同じロジック
        return Set(text.lowercased().components(separatedBy: .whitespacesAndNewlines))
    }
}
```

**使用例**:
```swift
@Persistable
struct Article {
    #PrimaryKey<Article>([\.articleID])
    #Index<Article>(
        [\.content],
        type: FullTextIndexKind(
            analyzer: .standard,
            minWordLength: 3,
            stopWords: ["the", "a", "an", "is", "are"]
        )
    )

    var articleID: String
    var title: String
    var content: String
}

// 検索
let results = try await store.searchFullText(
    indexName: "Article_content",
    query: "Swift FoundationDB tutorial",
    limit: 10
)

// 結果からArticleを取得
for primaryKey in results {
    if let bytes = try await store.load(
        itemType: Article.persistableType,
        primaryKey: primaryKey,
        transaction: transaction
    ) {
        let article = try JSONDecoder().decode(Article.self, from: Data(bytes))
        print("Found: \(article.title)")
    }
}
```

---

## 5. 高度なトピック

### 5.1 スキーマ管理とマイグレーション

#### スキーマバージョニング

**Sources/FDBMyLayer/Schema.swift**:
```swift
import Foundation
import FDBCore

public struct Schema: Sendable {
    public let version: Int
    public let itemTypes: [any Persistable.Type]

    public init(version: Int, itemTypes: [any Persistable.Type]) {
        self.version = version
        self.itemTypes = itemTypes
    }

    public func itemType(named name: String) -> (any Persistable.Type)? {
        return itemTypes.first { $0.persistableType == name }
    }
}

// バージョン管理
public struct SchemaVersion: Codable {
    public let version: Int
    public let appliedAt: Date

    public init(version: Int, appliedAt: Date = Date()) {
        self.version = version
        self.appliedAt = appliedAt
    }
}
```

#### マイグレーション

**Sources/FDBMyLayer/Migration.swift**:
```swift
import Foundation
import FoundationDB
import FDBRuntime

public protocol Migration: Sendable {
    var version: Int { get }

    func apply(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) async throws

    func rollback(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) async throws
}

public final class MigrationManager: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let versionKey: FDB.Bytes

    public init(database: any DatabaseProtocol, subspace: Subspace) {
        self.database = database
        self.subspace = subspace
        self.versionKey = subspace.pack(Tuple(["__schema_version__"]))
    }

    public func getCurrentVersion() async throws -> Int {
        return try await database.withTransaction { transaction in
            guard let bytes = try await transaction.getValue(for: versionKey, snapshot: true) else {
                return 0
            }

            let data = Data(bytes)
            let schemaVersion = try JSONDecoder().decode(SchemaVersion.self, from: data)
            return schemaVersion.version
        }
    }

    public func applyMigrations(_ migrations: [Migration]) async throws {
        let currentVersion = try await getCurrentVersion()

        let pendingMigrations = migrations
            .filter { $0.version > currentVersion }
            .sorted { $0.version < $1.version }

        for migration in pendingMigrations {
            print("Applying migration version \(migration.version)...")

            try await migration.apply(database: database, subspace: subspace)

            try await database.withTransaction { transaction in
                let schemaVersion = SchemaVersion(version: migration.version)
                let data = try JSONEncoder().encode(schemaVersion)
                transaction.setValue(Array(data), for: versionKey)
            }

            print("Migration version \(migration.version) applied.")
        }
    }
}
```

**マイグレーション例**:
```swift
// V1 → V2: Userにemailフィールド追加
struct AddEmailToUserMigration: Migration {
    let version = 2

    func apply(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) async throws {
        let store = FDBStore(database: database, subspace: subspace)

        try await database.withTransaction { transaction in
            // 全Userをスキャン
            let itemSubspace = store.itemSubspace(for: "User")
            let (begin, end) = itemSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end),
                snapshot: false
            )

            for try await (key, valueBytes) in sequence {
                // V1 Userをデコード
                let data = Data(valueBytes)
                var userDict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

                // emailフィールドを追加（デフォルト値）
                if userDict["email"] == nil {
                    userDict["email"] = "unknown@example.com"
                }

                // V2 Userとして保存
                let newData = try JSONSerialization.data(withJSONObject: userDict)
                transaction.setValue(Array(newData), for: key)
            }
        }
    }

    func rollback(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) async throws {
        // emailフィールドを削除（逆マイグレーション）
        let store = FDBStore(database: database, subspace: subspace)

        try await database.withTransaction { transaction in
            let itemSubspace = store.itemSubspace(for: "User")
            let (begin, end) = itemSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end),
                snapshot: false
            )

            for try await (key, valueBytes) in sequence {
                let data = Data(valueBytes)
                var userDict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

                userDict.removeValue(forKey: "email")

                let newData = try JSONSerialization.data(withJSONObject: userDict)
                transaction.setValue(Array(newData), for: key)
            }
        }
    }
}

// 実行
let migrationManager = MigrationManager(database: database, subspace: rootSubspace)
try await migrationManager.applyMigrations([
    AddEmailToUserMigration()
])
```

### 5.2 パフォーマンス最適化

#### カバリングインデックス

**DataAccessでreconstruct実装**:
```swift
extension UserDataAccess {
    public var supportsReconstruction: Bool { true }

    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> User {
        // indexKey: [email, userID]
        // indexValue: [name] (covering fields)

        guard indexKey.elements.count == 2,
              let email = indexKey.elements[0] as? String,
              let userID = indexKey.elements[1] as? Int64 else {
            throw DataAccessError.reconstructionFailed
        }

        // Covering fieldsをデコード
        let coveringTuple = try Tuple.unpack(from: indexValue)
        guard let name = coveringTuple.elements.first as? String else {
            throw DataAccessError.reconstructionFailed
        }

        return User(userID: userID, email: email, name: name)
    }
}
```

**クエリでの利用**:
```swift
// Covering indexを使用してフェッチ不要
let users = try await recordStore.query(
    index: "user_by_email",
    predicate: .all,
    useCoveringIndex: true  // reconstruct()を使用
)
```

#### バッチ処理

```swift
public func bulkInsert(_ items: [Item]) async throws {
    // 複数トランザクションに分割（各トランザクション10MB以下）
    let batchSize = 1000

    for batch in items.chunked(into: batchSize) {
        try await database.withTransaction { transaction in
            for item in batch {
                let serialized = try dataAccess.serialize(item)
                let primaryKey = try dataAccess.extractPrimaryKey(
                    from: item,
                    using: primaryKeyExpression
                )

                try await store.save(
                    serialized,
                    for: itemType,
                    primaryKey: primaryKey,
                    transaction: transaction
                )
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
```

### 5.3 エラーハンドリング

#### カスタムエラー定義

```swift
public enum MyLayerError: Error, CustomStringConvertible {
    case itemNotFound(String)
    case invalidItemType(String)
    case serializationFailed(String)
    case deserializationFailed(String)
    case indexNotFound(String)
    case transactionFailed(Error)

    public var description: String {
        switch self {
        case .itemNotFound(let id):
            return "Item not found: \(id)"
        case .invalidItemType(let type):
            return "Invalid item type: \(type)"
        case .serializationFailed(let reason):
            return "Serialization failed: \(reason)"
        case .deserializationFailed(let reason):
            return "Deserialization failed: \(reason)"
        case .indexNotFound(let name):
            return "Index not found: \(name)"
        case .transactionFailed(let error):
            return "Transaction failed: \(error.localizedDescription)"
        }
    }
}
```

#### リトライロジック

```swift
public func saveWithRetry(
    _ item: Item,
    maxRetries: Int = 5
) async throws {
    var attempt = 0

    while attempt < maxRetries {
        do {
            try await save(item)
            return
        } catch let error as FDBError {
            // FDB固有のリトライ可能エラー
            if error.isRetryable {
                attempt += 1
                logger.warning("Retrying save (attempt \(attempt)/\(maxRetries))")

                // Exponential backoff
                let delay = Double(1 << attempt) * 0.1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                continue
            } else {
                throw error
            }
        }
    }

    throw MyLayerError.transactionFailed(
        NSError(domain: "MyLayer", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Max retries exceeded"
        ])
    )
}
```

### 5.4 テスト戦略

#### ユニットテスト

```swift
import XCTest
import FoundationDB
@testable import FDBMyLayer

final class MyLayerTests: XCTestCase {
    var database: any DatabaseProtocol!
    var store: MyStore!
    var testSubspace: Subspace!

    override func setUp() async throws {
        try await FDBClient.initialize()
        database = try FDBClient.openDatabase()

        // テスト用の一意なサブスペースを作成
        let testID = UUID().uuidString
        testSubspace = Subspace(prefix: Tuple("test", testID).pack())

        store = MyStore(database: database, subspace: testSubspace)
    }

    override func tearDown() async throws {
        // テストデータをクリーンアップ
        try await database.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    func testSaveAndLoad() async throws {
        let item = MyItem(id: "test-1", value: "Hello")

        // 保存
        try await store.save(item)

        // 読み込み
        let loaded = try await store.load(id: "test-1")
        XCTAssertEqual(loaded?.value, "Hello")
    }

    func testConcurrentWrites() async throws {
        // 並行書き込みテスト
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let item = MyItem(id: "concurrent-\(i)", value: "Value \(i)")
                    try? await self.store.save(item)
                }
            }
        }

        // 全件読み込み
        let items = try await store.scanAll(prefix: "concurrent-")
        XCTAssertEqual(items.count, 10)
    }
}
```

#### モックとスタブ

```swift
// MockDataAccess（テスト用）
struct MockDataAccess<Item: Codable & Sendable>: DataAccess {
    var mockFields: [String: any TupleElement] = [:]

    func itemType(for item: Item) -> String {
        return String(describing: Item.self)
    }

    func extractField(from item: Item, fieldName: String) throws -> [any TupleElement] {
        guard let value = mockFields[fieldName] else {
            throw DataAccessError.fieldNotFound(
                itemType: String(describing: Item.self),
                fieldName: fieldName
            )
        }
        return [value]
    }

    func serialize(_ item: Item) throws -> FDB.Bytes {
        let data = try JSONEncoder().encode(item)
        return Array(data)
    }

    func deserialize(_ bytes: FDB.Bytes) throws -> Item {
        let data = Data(bytes)
        return try JSONDecoder().decode(Item.self, from: data)
    }
}

// 使用例
func testIndexMaintainer() async throws {
    var dataAccess = MockDataAccess<User>()
    dataAccess.mockFields = [
        "email": "alice@example.com",
        "userID": Int64(123)
    ]

    let maintainer = ScalarIndexMaintainer<User>(
        index: testIndex,
        subspace: testSubspace
    )

    let user = User(userID: 123, email: "alice@example.com", name: "Alice")

    try await database.withTransaction { transaction in
        try await maintainer.updateIndex(
            oldItem: nil,
            newItem: user,
            dataAccess: dataAccess,
            transaction: transaction
        )
    }

    // インデックスキーが正しく作成されたか確認
    let expectedKey = testSubspace.pack(Tuple(["alice@example.com", Int64(123)]))
    let value = try await database.withTransaction { transaction in
        try await transaction.getValue(for: expectedKey, snapshot: true)
    }

    XCTAssertNotNil(value)
}
```

### 5.5 マルチテナンシー

#### テナント分離

```swift
public final class MultiTenantStore: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let container: FDBContainer

    public init(database: any DatabaseProtocol) {
        self.database = database
        self.container = FDBContainer(database: database)
    }

    /// テナント別のストアを取得
    public func store(for tenantID: String) async throws -> FDBStore {
        // テナントごとに独立したディレクトリを作成
        let directory = try await container.getOrOpenDirectory(
            path: ["tenants", tenantID, "data"]
        )

        return FDBStore(
            database: database,
            subspace: directory.subspace
        )
    }

    /// テナント削除（全データ削除）
    public func deleteTenant(_ tenantID: String) async throws {
        try await container.removeDirectory(path: ["tenants", tenantID])
    }
}

// 使用例
let multiTenantStore = MultiTenantStore(database: database)

// Tenant A用のストア
let storeA = try await multiTenantStore.store(for: "tenant-a")
try await storeA.save(userDataA, for: "User", primaryKey: Tuple([1]))

// Tenant B用のストア（完全に分離）
let storeB = try await multiTenantStore.store(for: "tenant-b")
try await storeB.save(userDataB, for: "User", primaryKey: Tuple([1]))

// Tenant削除
try await multiTenantStore.deleteTenant("tenant-a")
```

---

## 6. 付録

### 6.1 実装チェックリスト

#### 最小限の実装（必須）

- [ ] **データモデル定義**
  - [ ] `@Persistable`構造体を定義
  - [ ] `#PrimaryKey`を宣言
  - [ ] フィールド定義（Codable準拠）

- [ ] **DataAccess実装**
  - [ ] `itemType(for:)` - ItemType名を返す
  - [ ] `extractField(from:fieldName:)` - フィールド抽出
  - [ ] `serialize(_:)` / `deserialize(_:)` - シリアライゼーション

- [ ] **LayerConfiguration実装**
  - [ ] `itemTypes` - サポートするItemType一覧
  - [ ] `makeDataAccess(for:)` - DataAccessファクトリ
  - [ ] `makeIndexMaintainer(for:itemType:subspace:)` - IndexMaintainerファクトリ

- [ ] **ストアAPI実装**
  - [ ] 基本CRUD操作（save/load/delete）
  - [ ] トランザクションサポート

#### インデックスサポート（オプション）

- [ ] **IndexMaintainer実装**
  - [ ] `updateIndex(oldItem:newItem:dataAccess:transaction:)` - インデックス更新
  - [ ] `scanItem(_:primaryKey:dataAccess:transaction:)` - バッチ構築

- [ ] **Scalar Index** (VALUE index)
  - [ ] 単一フィールドインデックス
  - [ ] 複合インデックス
  - [ ] Unique制約

- [ ] **カスタムIndexKind**
  - [ ] `IndexKind`実装
  - [ ] `validateTypes(_:)` - 型検証
  - [ ] 専用IndexMaintainer

#### 高度な機能（オプション）

- [ ] **クエリAPI**
  - [ ] プレディケート対応
  - [ ] 範囲クエリ
  - [ ] ソート・リミット

- [ ] **スキーマ管理**
  - [ ] バージョニング
  - [ ] マイグレーション

- [ ] **パフォーマンス**
  - [ ] カバリングインデックス
  - [ ] バッチ処理
  - [ ] キャッシング

- [ ] **エラーハンドリング**
  - [ ] カスタムエラー型
  - [ ] リトライロジック

- [ ] **テスト**
  - [ ] ユニットテスト
  - [ ] 統合テスト
  - [ ] パフォーマンステスト

### 6.2 トラブルシューティング

#### 問題: 型消去エラー

**症状**:
```
Cannot convert value of type 'MyDataAccess' to expected argument type 'any DataAccess<Item>'
```

**解決策**:
```swift
// ❌ 間違い
public func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
    return MyDataAccess()  // Item型が不一致
}

// ✅ 正しい
public func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
    return MyDataAccess() as! any DataAccess<Item>  // 明示的な型キャスト
}
```

#### 問題: IndexMaintainerが呼ばれない

**症状**: `updateIndex`が実行されない

**原因**: インデックスがIndexManagerに登録されていない、または上位レイヤーがIndexMaintainerを呼び出していない

**解決策**:
```swift
// 1. IndexManagerを作成
let indexManager = IndexManager(database: database, subspace: indexSubspace)

// 2. インデックスを登録
let index = Index(
    name: "MyIndex",
    kind: ScalarIndexKind(),
    rootExpression: FieldKeyExpression(fieldName: "myField"),
    subspaceKey: "MyIndex",
    recordTypes: ["MyItem"]
)
try indexManager.register(index: index)

// 3. 上位レイヤー（RecordStore等）でsave時にIndexMaintainerを呼び出す
// (上位レイヤーの実装責任)
let maintainer = try layerConfig.makeIndexMaintainer(
    for: index,
    itemType: "MyItem",
    subspace: indexManager.indexSubspace(for: index)
)
try await maintainer.updateIndex(
    oldItem: nil,
    newItem: item,
    dataAccess: dataAccess,
    transaction: transaction
)
```

#### 問題: Tuple変換エラー

**症状**:
```
Value of type 'Data' does not conform to protocol 'TupleElement'
```

**解決策**:
```swift
// ❌ DataはTupleElementではない
let tuple = Tuple([data])

// ✅ Base64文字列に変換
let tuple = Tuple([data.base64EncodedString()])

// または、[UInt8]に変換
let tuple = Tuple([Array(data)])
```

#### 問題: トランザクションタイムアウト

**症状**: 長時間実行でエラー

**解決策**:
```swift
// 1. トランザクションを分割
for batch in items.chunked(into: 1000) {
    try await database.withTransaction { transaction in
        // バッチ処理
    }
}

// 2. タイムアウトを延長
try transaction.setOption(to: nil, forOption: .timeout(10_000))  // 10秒
```

### 6.3 よくある質問（FAQ）

**Q1: FDBStoreとItemStoreの違いは？**

A:
- **FDBStore**: 型非依存の低レベルストア（`Data`を扱う）
- **ItemStore**: 型付きの高レベルストア（`Item`を扱う）

通常、ItemStoreがFDBStoreをラップしてユーザー向けAPIを提供します。

---

**Q2: 複数のLayerConfigurationを同時に使える？**

A: はい、可能です。LayerConfigurationは上位レイヤー（RecordStore、DocumentStore等）が実装するプロトコルで、各レイヤーが独自のFDBStoreインスタンスを持つか、同じFDBStoreを共有できます。

```swift
// 方法1: 各レイヤーが独立したFDBStoreを持つ（推奨）
let recordStore = RecordStore(
    database: database,
    schema: recordSchema,
    subspace: subspace.subspace("records")
)

let docStore = DocumentStore(
    database: database,
    schema: docSchema,
    subspace: subspace.subspace("documents")
)

// 方法2: 同じFDBStoreを共有（上位レイヤーで適切にitemTypeを分離）
let sharedStore = FDBStore(database: database, subspace: subspace)
// recordConfig、docConfigは各レイヤーのDataAccess/IndexMaintainer生成に使用
```

---

**Q3: インデックスなしでも動作する？**

A: はい、インデックスはオプションです。基本的なCRUD操作のみであれば、IndexMaintainerの実装は不要です。

---

**Q4: シリアライゼーション形式は変更できる？**

A: はい、`DataAccess`の`serialize`/`deserialize`メソッドで自由に実装できます（JSON, Protobuf, MessagePackなど）。

---

**Q5: マルチテナントはどう実装する？**

A: `FDBContainer`のディレクトリ機能を使用してテナントごとにサブスペースを分離します（セクション5.5参照）。

---

**Q6: パフォーマンスベストプラクティスは？**

A:
1. トランザクションサイズを10MB以下に保つ
2. バッチ処理を使用
3. Snapshot読み取りを活用（競合を避ける）
4. カバリングインデックスを使用（フェッチ削減）
5. 範囲クエリでlimitを指定

---

**Q7: エラーハンドリングのベストプラクティスは？**

A:
1. FDBError.isRetryableを確認してリトライ
2. カスタムエラー型で意味のあるエラーメッセージ
3. ログを適切に記録（Loggingフレームワーク使用）
4. トランザクション失敗時のロールバック戦略

---

**Q8: テスト時のFDB依存をモック化できる？**

A: `DatabaseProtocol`と`TransactionProtocol`をモック実装してテスト可能です。

```swift
class MockDatabase: DatabaseProtocol {
    var storage: [FDB.Bytes: FDB.Bytes] = [:]

    func withTransaction<T>(_ block: (any TransactionProtocol) async throws -> T) async throws -> T {
        let transaction = MockTransaction(storage: &storage)
        return try await block(transaction)
    }
}
```

---

### 6.4 参考リンク

#### 公式ドキュメント

- [FoundationDB公式](https://www.foundationdb.org/)
- [fdb-swift-bindings](https://github.com/kirilltitov/fdb-swift)
- [FoundationDB Record Layer (Java版)](https://github.com/FoundationDB/fdb-record-layer)

#### 設計パターン

- [Visitor Pattern](https://refactoring.guru/design-patterns/visitor) - KeyExpression評価で使用
- [Factory Pattern](https://refactoring.guru/design-patterns/factory-method) - LayerConfigurationで使用
- [Type Erasure](https://www.swiftbysundell.com/articles/different-flavors-of-type-erasure-in-swift/) - IndexKindで使用

#### サンプルコード

このガイドの完全なサンプルコードは以下のリポジトリで公開されています：

- [fdb-kv-layer-example](https://github.com/example/fdb-kv-layer)
- [fdb-graph-layer-example](https://github.com/example/fdb-graph-layer)
- [fdb-timeseries-layer-example](https://github.com/example/fdb-timeseries-layer)

---

## まとめ

このガイドでは、**fdb-runtime**上に独自のデータモデルレイヤーを構築する方法を解説しました。

**重要なポイント**:

1. **LayerConfiguration** - レイヤー全体の設定とファクトリ
2. **DataAccess\<Item\>** - フィールドアクセスとシリアライゼーション
3. **IndexMaintainer\<Item\>** - インデックス更新ロジック
4. **ItemStore\<Item\>** - ユーザー向け型付きAPI

**次のステップ**:

1. クイックスタート（セクション2）で基本を理解
2. プロトコルリファレンス（セクション3）で詳細を学習
3. 実践的な完全実装例（セクション4）で具体的な実装パターンを参照
4. 高度なトピック（セクション5）でプロダクション対応

**質問・フィードバック**:

このガイドに関する質問やフィードバックは、GitHubのIssueまでお願いします。

Happy Coding! 🚀
