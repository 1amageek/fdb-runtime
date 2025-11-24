# FDBRuntime アーキテクチャ設計

**Last Updated**: 2025-11-22

## 概要

FDBRuntime は、FoundationDB 上で複数のデータモデル層をサポートするための抽象基盤層です。型非依存の共通ストア（FDBStore）とプロトコル定義（IndexMaintainer, DataAccess）を提供し、各上位レイヤーで具体的な実装を行います。

## 設計目標

1. **単一ストアの共通使用**: すべてのデータモデル層で FDBStore を共通使用（型非依存）
2. **プロトコル層**: FDBRuntime はインターフェース定義のみ、実装は各上位レイヤー
3. **複数データモデル**: Record、Document、Vector、Graph など、異なるデータモデルを統一基盤でサポート
4. **責任分離**: メタデータ、コア、抽象基盤、データモデル層の明確な分離
5. **拡張性**: 新しいデータモデル層を追加可能なプロトコルベース設計

## アーキテクチャ全体図

```
┌─────────────────────────────────────────────────────────┐
│                   FDBIndexing                            │
│  役割: インデックスメタデータ定義（プロトコル + 組み込み型）│
│  依存: FoundationDB (fdb-swift-bindings)                 │
│  プラットフォーム: macOS, Linux (Server専用)               │
│                                                          │
│  ✅ IndexKind protocol                                   │
│  ✅ IndexDescriptor                                      │
│  ✅ LayerConfiguration protocol                         │
│  ✅ DataAccess<Item> protocol                           │
│  ✅ IndexMaintainer<Item> protocol                      │
│  ✅ Index, KeyExpression                                │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│              fdb-runtime/FDBCore                         │
│  役割: FDB非依存のコア機能 (Server-Client共通)             │
│  依存: Swift stdlib + Foundation + FDBIndexing (metadata)│
│  プラットフォーム: iOS, macOS, Linux (全プラットフォーム)    │
│                                                          │
│  ✅ Persistableプロトコル (FDB非依存)                     │
│  ✅ @Persistableマクロ (FDBCoreMacros)                   │
│  ✅ #PrimaryKey, #Index, #Directory マクロ                │
│  ✅ EnumMetadata                                         │
│  ✅ Codable準拠                                          │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│             fdb-runtime/FDBRuntime                       │
│  役割: 抽象基盤層（プロトコル定義 + 共通実装）              │
│  依存: FDBCore + FDBIndexing + FoundationDB              │
│  プラットフォーム: macOS, Linux (Server専用)               │
│                                                          │
│  【共通実装】                                             │
│  ✅ FDBStore - 型非依存ストア（全レイヤーで共通使用）       │
│  ✅ FDBContainer - コンテナ管理                          │
│  ✅ FDBContext - 変更追跡                                │
│  ✅ IndexManager - Index登録・管理システム                │
│                                                          │
│  【プロトコル実装】                                       │
│  ✅ IndexMaintainer<Item> protocol (in FDBIndexing)      │
│  ✅ DataAccess<Item> protocol (in FDBIndexing)          │
│                                                          │
│  【ビルトインIndexKind】                                  │
│  ✅ ScalarIndexKind, CountIndexKind, SumIndexKind, etc.  │
└────────────┬────────────────────────────────────────────┘
             │ 各データモデル層で実装
             ├─────────────────┬──────────────┬───────────┐
             │                 │              │           │
             ▼                 ▼              ▼           ▼
┌─────────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐
│ fdb-record-layer│ │fdb-document │ │fdb-vector│ │fdb-graph │
│                 │ │   -layer    │ │  -layer  │ │  -layer  │
├─────────────────┤ ├─────────────┤ ├──────────┤ ├──────────┤
│ FDBStore拡張    │ │FDBStore拡張 │ │FDBStore  │ │FDBStore  │
│ (型安全API)     │ │(Doc API)    │ │拡張      │ │拡張      │
│                 │ │             │ │(Vector   │ │(Graph    │
│ DataAccess      │ │DataAccess   │ │API)      │ │API)      │
│ 実装            │ │実装         │ │          │ │          │
│                 │ │             │ │DataAccess│ │DataAccess│
│ IndexMaintainer │ │IndexMaint   │ │実装      │ │実装      │
│ 実装群:         │ │実装群       │ │          │ │          │
│ - ValueIndex    │ │- DocIndex   │ │Vector    │ │Graph     │
│ - CountIndex    │ │- TextSearch │ │IndexMaint│ │IndexMaint│
│ - VectorIndex   │ │- Aggregation│ │実装      │ │実装      │
│ - etc.          │ │             │ │          │ │          │
│                 │ │             │ │          │ │          │
│ QueryPlanner    │ │QueryEngine  │ │Similarity│ │Traversal │
│                 │ │             │ │Search    │ │Queries   │
│                 │ │             │ │          │ │          │
│ Persistable型   │ │Document型   │ │Vector型  │ │Graph型   │
└─────────────────┘ └─────────────┘ └──────────┘ └──────────┘
```

## 重要な設計決定

### 決定1: FDBStore は全レイヤーで共通使用

**理由**:
- 型非依存の共通基盤により、複数のデータモデル層をサポート
- **RecordStore, DocumentStore などは作らず**、FDBStore を再利用
- 各レイヤーは extension や wrapper で型安全性を追加

**利点**:
- コードの重複削減
- 一貫した動作保証
- メンテナンス性向上

**実装例**:
```swift
// FDBRuntime: 型非依存の共通ストア
public final class FDBStore: Sendable {
    // 明示的トランザクション版（同期）
    public func save(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) throws

    // トランザクション自動生成版（非同期）
    public func save(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement
    ) async throws

    // 読み込み（非同期）
    public func load(
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) async throws -> Data?

    // 削除（同期 + 非同期版）
    public func delete(
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) throws
}

// fdb-record-layer: 型安全な拡張
public struct RecordStore<Record: Persistable> {
    private let store: FDBStore

    public func save(_ record: Record) async throws {
        let data = try serialize(record)
        let primaryKey = extractPrimaryKey(record)

        // 非同期版を使用（内部でトランザクション生成）
        try await store.save(
            data: data,
            for: Record.persistableType,
            primaryKey: primaryKey
        )

        // または明示的トランザクション版
        try await database.withTransaction { transaction in
            try store.save(
                data: data,
                for: Record.persistableType,
                primaryKey: primaryKey,
                transaction: transaction
            )
            // IndexMaintainer を呼び出してインデックス更新
        }
    }
}
```

### 決定2: FDBIndexing はプロトコル層（FoundationDB依存）

**理由**:
- IndexMaintainer と DataAccess のプロトコル定義を FDBIndexing に配置
- これらのプロトコルは FoundationDB 型（Tuple, Subspace, TransactionProtocol）を使用
- 具体的な実装は各上位レイヤーに配置
- 各データモデル層が独自の実装を提供可能

**利点**:
- 拡張性の向上
- 責任の明確化
- 新しいデータモデル層の追加が容易

**プロトコル定義**:
```swift
// FDBIndexing: プロトコル定義
public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Sendable

    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws

    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws
}

public protocol DataAccess<Item>: Sendable {
    associatedtype Item: Sendable

    func itemType(for item: Item) -> String
    func evaluate(item: Item, expression: KeyExpression) throws -> [any TupleElement]
    func extractField(from item: Item, fieldName: String) throws -> [any TupleElement]
    func serialize(_ item: Item) throws -> FDB.Bytes
    func deserialize(_ bytes: FDB.Bytes) throws -> Item
}
```

### 決定3: 複数データモデルのサポート

**理由**:
- Record（構造化）、Document（柔軟）、Vector（埋め込み）、Graph（関係性）など、異なるニーズに対応
- 統一された基盤（FDBStore）で一貫性を保ちながら、各層で最適化

**利点**:
- 用途に応じた最適なデータモデルの選択
- 統一された永続化基盤
- クロスモデルクエリの可能性

### 決定4: 用語の使い分け（"Item" vs "Record"）

**理由**:
- FDBRuntime層では型非依存の "item" を使用
- 上位レイヤー（fdb-record-layer等）では型依存の "record" を使用
- 抽象化レベルの違いを明確化

**用語マッピング**:

| レイヤー | 用語 | 意味 | 型 |
|---------|------|------|-----|
| **FDBRuntime** | **item** | 型非依存のデータ単位 | `Data` (生バイト) |
| **上位レイヤー** | **record/document/vector** | 型依存のデータ単位 | `Persistable`, `Document` など |

**実装例**:
```swift
// FDBStore API (型非依存 - "item" 用語を使用)
// 非同期版（トランザクション自動生成）
func save(data: Data, for itemType: String, primaryKey: any TupleElement) async throws

// 同期版（明示的トランザクション）
func save(data: Data, for itemType: String, primaryKey: any TupleElement, transaction: any TransactionProtocol) throws

// RecordStore API (型依存 - "record" 用語を使用)
func save(_ record: Record) async throws
func load(primaryKey: any TupleElement) async throws -> Record?
```

## データフロー

### 保存フロー（fdb-record-layer の例）

```
1. User code:
   recordStore.save(user)

2. RecordStore (fdb-record-layer):
   - DataAccess 実装で user をシリアライズ
   - database.withTransaction { transaction in
       try store.save(
           data: serializedData,
           for: "User",
           primaryKey: pk,
           transaction: transaction
       )
       // IndexMaintainer 実装群を呼び出し
     }

3. FDBStore (fdb-runtime):
   - Subspace 解決: itemSubspace.subspace("User")
   - Key 生成: effectiveSubspace.subspace(pk).pack(Tuple())
   - transaction.setValue(Array(data), for: key)  // 同期メソッド

4. IndexMaintainer 実装 (fdb-record-layer):
   - ValueIndexMaintainer.updateIndex(oldItem: nil, newItem: user, ...)
   - IndexSubspace にエントリ作成
```

### 読み取りフロー（fdb-record-layer の例）

```
1. User code:
   let users = try await recordStore.query()
       .where(\.email, .equals, "test@example.com")
       .execute()

2. RecordStore (fdb-record-layer):
   - QueryPlanner でプラン作成（インデックススキャン vs フルスキャン）
   - IndexMaintainer からインデックスエントリ読み取り
   - database.withTransaction { transaction in
       try await store.load(
           for: "User",
           primaryKey: pk,
           transaction: transaction
       )
     }

3. FDBStore (fdb-runtime):
   - Subspace 解決: itemSubspace.subspace("User")
   - Key 生成: effectiveSubspace.subspace(pk).pack(Tuple())
   - let bytes = try await transaction.getValue(for: key, snapshot: false)
   - return bytes.map { Data($0) }  // 非同期メソッド

4. RecordStore (fdb-record-layer):
   - DataAccess 実装で data をデシリアライズ
   - User インスタンスを返す
```

## 拡張性

### 新しいデータモデル層の追加

1. **FDBStore 拡張**: 型安全なAPIを追加
   ```swift
   extension FDBStore {
       func saveDocument(_ doc: Document, ...) async throws { ... }
   }
   ```

2. **DataAccess 実装**: データアクセスロジックを提供
   ```swift
   struct DocumentDataAccess: DataAccess {
       typealias Item = Document

       func itemType(for item: Document) -> String {
           return item.collection
       }

       func extractField(from item: Document, fieldName: String) throws -> [any TupleElement] {
           // JSONパス抽出ロジック
       }

       func serialize(_ item: Document) throws -> FDB.Bytes {
           return try JSONEncoder().encode(item)
       }

       func deserialize(_ bytes: FDB.Bytes) throws -> Document {
           return try JSONDecoder().decode(Document.self, from: Data(bytes))
       }
   }
   ```

3. **IndexMaintainer 実装**: インデックス維持ロジックを提供
   ```swift
   struct DocumentIndexMaintainer: IndexMaintainer {
       typealias Item = Document

       func updateIndex(
           oldItem: Document?,
           newItem: Document?,
           dataAccess: any DataAccess<Document>,
           transaction: any TransactionProtocol
       ) async throws {
           // インデックス更新ロジック
       }

       func scanItem(
           _ item: Document,
           primaryKey: Tuple,
           dataAccess: any DataAccess<Document>,
           transaction: any TransactionProtocol
       ) async throws {
           // バッチインデックス構築ロジック
       }
   }
   ```

4. **LayerConfiguration 実装**: レイヤー全体の設定を提供
   ```swift
   struct DocumentLayerConfiguration: LayerConfiguration {
       var itemTypes: Set<String> {
           return Set(schema.collections.map(\.name))
       }

       func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
           guard let collection = schema.collection(named: itemType) else {
               throw ConfigurationError.unsupportedItemType(itemType)
           }
           return DocumentDataAccess() as! any DataAccess<Item>
       }

       func makeIndexMaintainer<Item>(
           for index: Index,
           itemType: String,
           subspace: Subspace
       ) throws -> any IndexMaintainer<Item> {
           switch index.kind.identifier {
           case "scalar":
               return DocumentScalarIndexMaintainer(index: index, subspace: subspace) as! any IndexMaintainer<Item>
           case "fulltext":
               return FullTextIndexMaintainer(index: index, subspace: subspace) as! any IndexMaintainer<Item>
           default:
               throw ConfigurationError.unsupportedIndexKind(index.kind.identifier)
           }
       }
   }
   ```

## 各データモデル層の詳細

### fdb-record-layer（レコード層）

**役割**: 構造化レコードの型安全な操作

**実装内容**:
- RecordStore<Record: Persistable> - FDBStore の型安全なラッパー
- DataAccess<Record: Persistable> の実装
- IndexMaintainer 実装群（ValueIndexMaintainer, CountIndexMaintainer, etc.）
- QueryPlanner - クエリプラン最適化

**使用例**:
```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], type: ScalarIndexKind())

    var userID: Int64
    var email: String
    var name: String
}

let recordStore = RecordStore<User>(store: store, schema: schema)
try await recordStore.save(user)
```

### fdb-document-layer（ドキュメント層）

**想定される実装**:
- 柔軟なスキーマレスドキュメント
- JSON/BSON ベースのシリアライズ
- テキスト検索インデックス
- 集約パイプライン

**使用例**:
```swift
struct Document {
    var id: String
    var collection: String
    var data: [String: Any]
}

let documentStore = DocumentStore(store: store)
try await documentStore.insert(document, into: "users")
```

### fdb-vector-layer（ベクトル層）

**想定される実装**:
- 高次元ベクトル埋め込み
- HNSW/IVF インデックス
- 類似度検索（cosine, L2, inner product）
- バッチベクトル操作

**使用例**:
```swift
@Persistable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            metric: .cosine,
            algorithm: .hnsw(HNSWParameters(m: 16, efConstruction: 200))
        )
    )

    var productID: Int64
    var embedding: [Float32]
}

let vectorStore = VectorStore<Product>(store: store)
let similar = try await vectorStore.search(query: embedding, k: 10)
```

### fdb-graph-layer（グラフ層）

**想定される実装**:
- ノード・エッジモデル
- トラバーサルクエリ
- 最短経路探索
- PageRank などのアルゴリズム

**使用例**:
```swift
@Persistable
struct Node {
    #PrimaryKey<Node>([\.nodeID])
    var nodeID: String
    var label: String
    var properties: [String: PropertyValue]
}

@Persistable
struct Edge {
    #PrimaryKey<Edge>([\.edgeID])
    #Index<Edge>([\.fromNodeID, \.label], type: ScalarIndexKind())
    #Index<Edge>([\.toNodeID, \.label], type: ScalarIndexKind())

    var edgeID: String
    var fromNodeID: String
    var toNodeID: String
    var label: String
}

let graphStore = GraphStore(store: store)
let neighbors = try await graphStore.getNeighbors(nodeID: "alice", edgeLabel: "FOLLOWS")
```

## Subspace構造

FDBStoreは2つのサブスペースを使用してデータを整理します：

```
[rootSubspace]
  ├── [R]/                    # Item storage (Records)
  │   ├── [User]/
  │   │   └── [123] = <serialized User data>
  │   └── [Product]/
  │       └── [456] = <serialized Product data>
  │
  └── [I]/                    # Index storage
      ├── [user_by_email]/
      │   └── ["alice@example.com"]/[123] = ''
      └── [product_by_category]/
          └── ["Electronics"]/[456] = ''
```

**キー構造**:
- **Item storage**: `[R]/[itemType]/[primaryKey] = data`
- **Index storage**: `[I]/[indexName]/[indexedValue]/[primaryKey] = ''`

**注意**: サブスペースプレフィックス "R" は後方互換性のため維持されています（"item" への用語変更後も変わらず）。

## まとめ

FDBRuntime は、複数のデータモデル層を統一基盤でサポートするための抽象基盤層です。型非依存の FDBStore とプロトコル定義により、柔軟で拡張性の高いアーキテクチャを実現しています。

**キーポイント**:
- ✅ **FDBStore は全レイヤーで共通使用**（RecordStore, DocumentStore などは作らない）
- ✅ **FDBIndexing はプロトコル層**（実装は各上位レイヤー）
- ✅ **複数データモデル**（Record, Document, Vector, Graph）をサポート
- ✅ **明確な責任分離**とレイヤー構造
- ✅ **拡張性の高い設計**（新しいデータモデル層を追加可能）
- ✅ **用語の一貫性**（FDBRuntime層では "item"、上位レイヤーでは "record/document/vector" など）

**プロトコル実装のポイント**:
1. **DataAccess<Item>**: アイテムのフィールドアクセス・シリアライゼーション
2. **IndexMaintainer<Item>**: インデックス更新ロジック（`updateIndex`, `scanItem`）
3. **LayerConfiguration**: レイヤー全体の設定とファクトリメソッド

詳細な実装ガイドは [Layer Implementation Guide](LAYER_IMPLEMENTATION_GUIDE.md) を参照してください。

---

**Last Updated**: 2025-11-22
