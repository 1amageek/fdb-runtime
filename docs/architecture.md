# FDBRuntime アーキテクチャ設計

**Last Updated**: 2025-11-29

## 概要

FDBRuntime は、FoundationDB 上で複数のデータモデル層をサポートするための抽象基盤層です。型非依存の共通ストア（FDBStore）、IndexMaintainerプロトコル、DataAccess静的ユーティリティを提供し、各上位レイヤーで具体的な実装を行います。

## 設計目標

1. **単一ストアの共通使用**: すべてのデータモデル層で FDBStore を共通使用（型非依存）
2. **プロトコル層**: IndexMaintainerはプロトコル、DataAccessは静的ユーティリティ
3. **複数データモデル**: Record、Document、Vector、Graph など、異なるデータモデルを統一基盤でサポート
4. **責任分離**: メタデータ、コア、抽象基盤、データモデル層の明確な分離
5. **拡張性**: 新しいデータモデル層を追加可能なプロトコルベース設計

## アーキテクチャ全体図

```
┌─────────────────────────────────────────────────────────┐
│                     FDBModel                             │
│  役割: モデル定義・メタデータ (FDB非依存、全プラットフォーム)│
│  依存: Swift stdlib + Foundation                         │
│  プラットフォーム: iOS, macOS, Linux (全プラットフォーム)    │
│                                                          │
│  ✅ Persistable プロトコル                               │
│  ✅ @Persistable マクロ (FDBModelMacros)                 │
│  ✅ #Index, #Directory マクロ                            │
│  ✅ IndexKind protocol + StandardIndexKinds             │
│     (Scalar, Count, Sum, Min, Max, Version)             │
│  ✅ IndexDescriptor, CommonIndexOptions                 │
│  ✅ TypeValidation ヘルパー                              │
│  ✅ ULID (自動生成ID)                                   │
│  ✅ EnumMetadata                                        │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                      FDBCore                             │
│  役割: スキーマ・シリアライゼーション (FDB非依存)          │
│  依存: FDBModel                                          │
│  プラットフォーム: iOS, macOS, Linux (全プラットフォーム)    │
│                                                          │
│  ✅ Schema (エンティティ定義、バージョニング)              │
│  ✅ ProtobufEncoder / ProtobufDecoder                   │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                    FDBIndexing                           │
│  役割: インデックス抽象化層 (FDB依存、Server専用)         │
│  依存: FDBModel + FDBCore + FoundationDB                │
│  プラットフォーム: macOS, Linux (Server専用)               │
│                                                          │
│  ✅ IndexMaintainer<Item> プロトコル                     │
│  ✅ IndexKindMaintainable プロトコル                     │
│  ✅ DataAccess 静的ユーティリティ (プロトコルではない)     │
│  ✅ KeyExpression, KeyExpressionVisitor                 │
│  ✅ Index, IndexManager, IndexStateManager              │
│  ✅ OnlineIndexer                                       │
│  Note: IndexMaintainer実装はfdb-indexesパッケージで提供  │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                    FDBRuntime                            │
│  役割: ストア・コンテナ (FDB依存、Server専用)             │
│  依存: FDBModel + FDBCore + FDBIndexing + FoundationDB  │
│  プラットフォーム: macOS, Linux (Server専用)               │
│                                                          │
│  ✅ FDBStore - 型非依存ストア（全レイヤーで共通使用）       │
│  ✅ FDBContainer - スキーマ管理、ストアライフサイクル      │
│  ✅ FDBContext - 変更追跡、バッチ操作                    │
│  ✅ IDValidation - ID型検証                             │
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

### 決定2: FDBIndexing のプロトコルと静的ユーティリティ

**理由**:
- IndexMaintainer はプロトコルとして FDBIndexing に配置
- IndexKindMaintainable は IndexKind と IndexMaintainer を橋渡しするプロトコル
- DataAccess は静的ユーティリティとして FDBIndexing に配置（全 Persistable 型で共通）
- IndexMaintainer の具体的実装は **fdb-indexes** パッケージで提供

**利点**:
- IndexMaintainer: 各データモデル層が独自のインデックス維持ロジックを実装可能
- DataAccess: Persistable の `@dynamicMemberLookup` を活用した統一的なフィールドアクセス
- fdb-indexes パッケージでの実装分離: 標準 IndexKind (Scalar, Count, Sum, Min, Max, Version) の実装を提供

**定義**:
```swift
// FDBIndexing: IndexMaintainer プロトコル
public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Persistable

    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws

    func scanItem(
        _ item: Item,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws

    // オプション: カスタムバルクビルド戦略
    var customBuildStrategy: (any IndexBuildStrategy<Item>)? { get }
}

// FDBIndexing: DataAccess 静的ユーティリティ (プロトコルではない)
public struct DataAccess: Sendable {
    // プライベートinit - すべてのメソッドは静的

    /// KeyExpression を評価してフィールド値を抽出
    public static func evaluate<Item: Persistable>(
        item: Item,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    /// Persistable の subscript を使用して単一フィールドを抽出
    public static func extractField<Item: Persistable>(
        from item: Item,
        keyPath: String
    ) throws -> [any TupleElement]

    /// id 式を使用して ID を抽出
    public static func extractId<Item: Persistable>(
        from item: Item,
        using idExpression: KeyExpression
    ) throws -> Tuple

    /// ProtobufEncoder を使用してシリアライズ
    public static func serialize<Item: Persistable>(_ item: Item) throws -> FDB.Bytes

    /// ProtobufDecoder を使用してデシリアライズ
    public static func deserialize<Item: Persistable>(_ bytes: FDB.Bytes) throws -> Item
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

1. **型安全なラッパーストアの作成**: FDBStore を内部で使用
   ```swift
   public struct DocumentStore {
       private let store: FDBStore
       private let database: any DatabaseProtocol

       public func save(_ doc: Document) async throws {
           let data = try DataAccess.serialize(doc)
           let id = Tuple(doc.id)
           try await database.withTransaction { transaction in
               try store.save(
                   data: Data(data),
                   for: Document.persistableType,
                   id: id,
                   transaction: transaction
               )
           }
       }
   }
   ```

2. **IndexMaintainer 実装**: インデックス維持ロジックを提供
   ```swift
   struct DocumentIndexMaintainer<Item: Persistable>: IndexMaintainer {
       let index: Index
       let subspace: Subspace

       func updateIndex(
           oldItem: Item?,
           newItem: Item?,
           transaction: any TransactionProtocol
       ) async throws {
           // DataAccess静的メソッドを使用
           if let old = oldItem {
               let oldValues = try DataAccess.evaluate(item: old, expression: index.rootExpression)
               // 古いエントリを削除
           }
           if let new = newItem {
               let newValues = try DataAccess.evaluate(item: new, expression: index.rootExpression)
               // 新しいエントリを追加
           }
       }

       func scanItem(
           _ item: Item,
           id: Tuple,
           transaction: any TransactionProtocol
       ) async throws {
           let values = try DataAccess.evaluate(item: item, expression: index.rootExpression)
           // バッチインデックス構築ロジック
       }

       var customBuildStrategy: (any IndexBuildStrategy<Item>)? { nil }
   }
   ```

3. **カスタム IndexKind の追加** (オプション):
   ```swift
   // FDBModel を拡張して新しい IndexKind を追加
   public struct FullTextIndexKind: IndexKind {
       public static let identifier = "fulltext"
       public static let subspaceStructure = SubspaceStructure.hierarchical

       public let analyzer: String

       public init(analyzer: String = "standard") {
           self.analyzer = analyzer
       }

       public static func validateTypes(_ types: [Any.Type]) throws {
           for type in types {
               guard type == String.self else {
                   throw IndexTypeValidationError.unsupportedType(...)
               }
           }
       }
   }
   ```

## 各データモデル層の詳細

### fdb-record-layer（レコード層）

**役割**: 構造化レコードの型安全な操作

**実装内容**:
- RecordStore<Record: Persistable> - FDBStore の型安全なラッパー
- DataAccess 静的メソッドの使用（フィールド抽出、シリアライゼーション）
- IndexMaintainer 実装群（ScalarIndexMaintainer, CountIndexMaintainer, etc.）
- QueryPlanner - クエリプラン最適化

**使用例**:
```swift
@Persistable
struct User {
    // id は自動生成 (ULID) または明示的に定義
    var id: String = ULID().ulidString

    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

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
- HNSW/IVF インデックス (fdb-indexes パッケージで提供予定)
- 類似度検索（cosine, L2, inner product）
- バッチベクトル操作

**使用例**:
```swift
@Persistable
struct Product {
    var id: Int64  // 明示的な Int64 ID

    // Note: VectorIndexKind は fdb-indexes パッケージで提供予定
    #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384))

    var name: String
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
    var id: String = ULID().ulidString

    var label: String
    var properties: [String: PropertyValue]
}

@Persistable
struct Edge {
    var id: String = ULID().ulidString

    #Index<Edge>([\.fromNodeID, \.label], type: ScalarIndexKind())
    #Index<Edge>([\.toNodeID, \.label], type: ScalarIndexKind())

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

FDBRuntime は、複数のデータモデル層を統一基盤でサポートするための抽象基盤層です。型非依存の FDBStore、IndexMaintainerプロトコル、DataAccess静的ユーティリティにより、柔軟で拡張性の高いアーキテクチャを実現しています。

**キーポイント**:
- ✅ **FDBStore は全レイヤーで共通使用**（RecordStore, DocumentStore などはラッパー）
- ✅ **4層モジュール構造**: FDBModel → FDBCore → FDBIndexing → FDBRuntime
- ✅ **複数データモデル**（Record, Document, Vector, Graph）をサポート
- ✅ **明確な責任分離**とレイヤー構造
- ✅ **拡張性の高い設計**（新しいデータモデル層を追加可能）
- ✅ **用語の一貫性**（FDBRuntime層では "item"、上位レイヤーでは "record/document/vector" など）
- ✅ **プラットフォーム分離**: FDBModel/FDBCore は全プラットフォーム、FDBIndexing/FDBRuntime はサーバー専用

**実装のポイント**:
1. **DataAccess 静的メソッド**: 全 Persistable 型で共通のフィールドアクセス・シリアライゼーション
2. **IndexMaintainer プロトコル**: インデックス更新ロジック（`updateIndex`, `scanItem`）
3. **IndexKindMaintainable プロトコル**: IndexKind と IndexMaintainer を橋渡し
4. **fdb-indexes パッケージ**: 標準 IndexMaintainer 実装（Scalar, Count, Sum, Min, Max, Version）

---

**Last Updated**: 2025-11-29
