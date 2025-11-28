# FDBContainer / FDBConfiguration 設計ドキュメント

## 概要

SwiftDataのModelContainer/ModelConfigurationアーキテクチャを参考に、fdb-runtime向けの設計を行う。
SwiftData互換性は目指さず、FDBの特性に最適化した独自実装とする。

## 現在のアーキテクチャ理解

### レイヤー構造

```
FDBModel (メタデータ、全プラットフォーム)
├── Persistable protocol + @Persistable macro
├── IndexKind protocol + StandardIndexKinds
├── IndexDescriptor (KeyPath保持、Codable)
└── TypeValidation, ULID, etc.

FDBIndexing (プロトコル + ユーティリティ、サーバーのみ)
├── IndexMaintainer protocol ← 実装は上位レイヤー
├── IndexKindMaintainable protocol ← IndexKindとIndexMaintainerの橋渡し
├── DataAccess (静的ユーティリティ)
├── Index (実行時定義)
├── KeyExpression (フィールドパス)
├── IndexState / IndexStateManager
└── OnlineIndexer (バッチビルド)

FDBRuntime (コンテナ/コンテキスト、サーバーのみ)
├── FDBConfiguration
├── FDBContainer (ライフサイクル管理)
├── FDBContext (変更追跡)
├── FDBDataStore (内部ストレージ)
└── Migration

上位レイヤー (fdb-indexes, fdb-record-layer 等)
├── IndexMaintainer 具体実装 (ScalarIndexMaintainer, VersionIndexMaintainer等)
├── IndexKindMaintainable 準拠 (extension VersionIndexKind: IndexKindMaintainable)
├── IndexManager (orchestration)
└── 型付きStore (RecordStore<T>等)
```

### 重要な設計原則

1. **IndexMaintainerは上位レイヤーで実装**: FDBIndexingはprotocolのみ提供
2. **FDBDataStoreは型非依存**: Data (bytes) で操作、上位が型安全性追加
3. **メタデータと実行時定義の分離**: IndexDescriptor → Index → IndexMaintainer
4. **IndexKindMaintainableによる橋渡し**: IndexKind（メタデータ）→ IndexMaintainer（実行時）

### IndexKindのパラメータ設計

現在、インデックスの設定は2つのレベルで行われる：

**1. マクロ時（IndexKind内）: 軽量なパラメータ**
```swift
// VersionIndexKind - 軽量な保持戦略
#Index<Document>([\.id], type: VersionIndexKind(strategy: .keepLast(10)))

// ScalarIndexKind - パラメータなし
#Index<User>([\.email], type: ScalarIndexKind(), unique: true)
```

**2. 初期化時（IndexConfiguration）: 重いパラメータ**
```swift
// HNSWParameters - メモリ集約型、環境依存
FDBConfiguration(
    indexConfigurations: [
        HNSWIndexConfiguration(
            indexName: "Document_embedding",
            dimensions: 1536,
            M: 16,
            efConstruction: 200,
            efSearch: 50
        )
    ]
)
```

---

## SwiftData アーキテクチャ理解

### ModelContainer

```swift
class ModelContainer {
    let schema: Schema                          // 全モデルのスキーマ
    var configurations: Set<ModelConfiguration> // ストレージ設定群
    var mainContext: ModelContext               // メインコンテキスト
}
```

**役割:**
- モデルのライフサイクル管理
- ストレージ調整
- スキーマとマイグレーション管理

### ModelConfiguration

```swift
struct ModelConfiguration: DataStoreConfiguration {
    let name: String?
    let schema: Schema?              // このConfigが担当するモデル（nil=全部）
    let url: URL                     // 保存先
    let isStoredInMemoryOnly: Bool   // メモリのみ
    let allowsSave: Bool             // 読み取り専用
    let cloudKitDatabase: CloudKitDatabase
    let groupContainer: GroupContainer
}
```

**役割:**
- 「どう保存するか」を定義
- モデルのサブセットに異なる設定を適用可能

### 関係性

```
ModelContainer (1つ)
├── schema: 全モデル [A, B, C, D]
├── configurations:
│   ├── Config1 (schema: [A, B]) → DefaultStore (SQLite永続化)
│   └── Config2 (schema: [C, D]) → MemoryStore (メモリのみ)
└── mainContext: ModelContext
```

---

## FDB向け設計

### 設計原則

1. **SwiftDataのAPI設計を参考**にするが、互換性は目指さない
2. **FDBの特性に最適化**（単一分散DB、ファイルレス）
3. **重いインデックス設定は初期化時に指定** (HNSW、全文検索等)
4. **IndexConfigurationはプロトコル** - あらゆるIndexKindが追加設定を持てる

### FDBで不要な機能

| SwiftData機能 | FDBでの扱い | 理由 |
|---------------|-------------|------|
| `cloudKitDatabase` | 不要 | FDB自体が分散DB |
| `groupContainer` | 不要 | サーバーサイド用途 |
| `isStoredInMemoryOnly` | **不要** | FDBはテストクラスタを使用。インメモリストアは不要 |
| `allowsSave` | **不要** | DataStore.save()の制御は開発者実装に依存し保証されない |
| `DataStoreConfiguration` protocol | 採用 | DataStore抽象化に必要 |

### FDBで必要な機能

| 機能 | 用途 |
|------|------|
| `schema` | モデル定義 |
| `url` | FDBクラスタファイルURL（SwiftData互換） |
| `indexConfigurations` | 実行時設定が必要なインデックス |
| `apiVersion` | FDB APIバージョン（ドキュメント用、実際はグローバル設定） |

---

## 提案設計

### IndexConfiguration プロトコル

**定義場所**: `FDBModel` (全プラットフォームで利用可能)

```swift
/// インデックスの実行時設定を定義するプロトコル
///
/// マクロで定義するIndexKindとは別に、デプロイ環境に依存する
/// 重いパラメータを初期化時に指定するために使用する。
///
/// **特徴**:
/// - KeyPathで対象インデックスを型安全に指定
/// - 同一インデックスに対して複数の設定を許容（例: 多言語全文検索）
/// - associated typeなしで `[any IndexConfiguration]` を直接使用可能
///
/// **例**:
/// - HNSW: dimensions, M, efConstruction, efSearch
/// - 全文検索: 言語別設定（ja, en等）
/// - カスタムインデックス: 任意のパラメータ
public protocol IndexConfiguration: Sendable {
    /// 対応するIndexKindの識別子
    ///
    /// 例: "vector", "fulltext", "scalar"
    static var kindIdentifier: String { get }

    /// 対象フィールドのKeyPath（型消去済み）
    ///
    /// モデルで定義した `#Index` のKeyPathと一致させる
    var keyPath: AnyKeyPath { get }

    /// 対象モデルの型名
    ///
    /// インデックス名の生成に使用: `{modelTypeName}_{fieldName}`
    var modelTypeName: String { get }
}

extension IndexConfiguration {
    /// インデックス名を生成
    ///
    /// 形式: `{ModelTypeName}_{fieldName}`
    /// 例: "Document_embedding", "Article_content"
    public var indexName: String {
        // KeyPathからフィールド名を取得する方法は実装時に決定
        // 暫定的にkeyPathの文字列表現を使用
        "\(modelTypeName)_\(String(describing: keyPath))"
    }
}
```

### 具体型の実装パターン

具体型はジェネリックで型安全性を保ちつつ、プロトコル要件はAnyKeyPathで満たす：

```swift
public struct VectorIndexConfiguration<Model: Persistable>: IndexConfiguration {
    public static var kindIdentifier: String { "vector" }

    // 内部では型付きKeyPathを保持
    private let _keyPath: KeyPath<Model, [Float]>

    // プロトコル要件はAnyKeyPathで満たす
    public var keyPath: AnyKeyPath { _keyPath }
    public var modelTypeName: String { String(describing: Model.self) }

    public let dimensions: Int
    public let hnswParameters: HNSWParameters
    public let loadIntoMemory: Bool

    public init(
        keyPath: KeyPath<Model, [Float]>,
        dimensions: Int,
        hnswParameters: HNSWParameters = .default,
        loadIntoMemory: Bool = false
    ) {
        self._keyPath = keyPath
        self.dimensions = dimensions
        self.hnswParameters = hnswParameters
        self.loadIntoMemory = loadIntoMemory
    }
}
```

### 使用例（ラップ不要）

```swift
@Persistable
struct Article {
    #Index<Article>([\.content], type: FullTextIndexKind())
    var title: String
    var content: String
}

// [any IndexConfiguration] を直接使用、ラップ不要
let config = FDBConfiguration(
    indexConfigurations: [
        FullTextIndexConfiguration<Article>(
            keyPath: \.content,
            language: "ja",
            tokenizer: .morphological
        ),
        FullTextIndexConfiguration<Article>(
            keyPath: \.content,
            language: "en",
            tokenizer: .standard
        )
    ]
)
```

### IndexConfigurationApplicable プロトコル

**定義場所**: `FDBIndexing` (サーバーのみ)

```swift
/// IndexConfigurationを受け取り、IndexMaintainerに適用するプロトコル
///
/// **責務**: IndexMaintainer実装者がこのプロトコルに準拠し、
/// 設定を受け取る方法を提供する
///
/// **設計**:
/// ```
/// IndexConfiguration (FDBModel)
///       ↓
/// IndexConfigurationApplicable (FDBIndexing)
///       ↓
/// HNSWIndexMaintainer (上位レイヤー)
/// ```
///
/// **使用例**:
/// ```swift
/// struct HNSWIndexMaintainer<Item: Persistable>: IndexMaintainer, IndexConfigurationApplicable {
///     typealias Configuration = VectorIndexConfiguration<Item>
///
///     private var dimensions: Int = 0
///     private var hnswParameters: HNSWParameters = .default
///
///     mutating func apply(configuration: Configuration) {
///         self.dimensions = configuration.dimensions
///         self.hnswParameters = configuration.hnswParameters
///     }
/// }
/// ```
public protocol IndexConfigurationApplicable {
    /// 対応するIndexConfiguration型
    associatedtype Configuration: IndexConfiguration

    /// 設定を適用する
    ///
    /// IndexMaintainer作成後に呼び出される
    mutating func apply(configuration: Configuration)
}

/// 複数のIndexConfigurationを受け取るプロトコル
///
/// **用途**: 多言語全文検索のように、同一インデックスに
/// 複数の設定が必要な場合に使用
///
/// **使用例**:
/// ```swift
/// struct FullTextIndexMaintainer<Item: Persistable>: IndexMaintainer, MultiIndexConfigurationApplicable {
///     typealias Configuration = FullTextIndexConfiguration<Item>
///
///     private var languageConfigs: [String: FullTextIndexConfiguration<Item>] = [:]
///
///     mutating func apply(configurations: [Configuration]) {
///         for config in configurations {
///             languageConfigs[config.language] = config
///         }
///     }
/// }
/// ```
public protocol MultiIndexConfigurationApplicable {
    /// 対応するIndexConfiguration型
    associatedtype Configuration: IndexConfiguration

    /// 複数の設定を適用する
    ///
    /// IndexMaintainer作成後に呼び出される
    mutating func apply(configurations: [Configuration])
}
```

### IndexKindMaintainable 拡張

**既存のプロトコルを拡張**:

```swift
public protocol IndexKindMaintainable: IndexKind {
    /// Create an IndexMaintainer for this IndexKind
    func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item>

    /// オプション: 対応するIndexConfiguration型
    ///
    /// nilの場合、このIndexKindはIndexConfigurationを必要としない
    /// （例: ScalarIndexKindはパラメータ不要）
    static var configurationKindIdentifier: String? { get }
}

// デフォルト実装: 設定不要
extension IndexKindMaintainable {
    public static var configurationKindIdentifier: String? { nil }
}
```

### 具体的なIndexConfiguration例

#### HNSWParameters (共通パラメータ)

```swift
public struct HNSWParameters: Sendable {
    /// グラフの接続数 (default: 16)
    public let M: Int

    /// 構築時の探索幅 (default: 200)
    public let efConstruction: Int

    /// 検索時の探索幅 (default: 50)
    public let efSearch: Int

    /// 距離関数
    public let distanceMetric: DistanceMetric

    public static let `default` = HNSWParameters(
        M: 16,
        efConstruction: 200,
        efSearch: 50,
        distanceMetric: .cosine
    )

    public enum DistanceMetric: String, Sendable, Codable {
        case euclidean
        case cosine
        case dotProduct
    }
}
```

#### FullTextIndexConfiguration (全文検索)

```swift
public struct FullTextIndexConfiguration<Model: Persistable>: IndexConfiguration {
    public static var kindIdentifier: String { "fulltext" }

    private let _keyPath: KeyPath<Model, String>

    public var keyPath: AnyKeyPath { _keyPath }
    public var modelTypeName: String { String(describing: Model.self) }

    /// 言語設定（同一フィールドに複数言語を設定可能）
    public let language: String

    /// トークナイザ種別
    public let tokenizer: TokenizerKind

    /// ストップワード除去
    public let removeStopWords: Bool

    public init(
        keyPath: KeyPath<Model, String>,
        language: String,
        tokenizer: TokenizerKind,
        removeStopWords: Bool = true
    ) {
        self._keyPath = keyPath
        self.language = language
        self.tokenizer = tokenizer
        self.removeStopWords = removeStopWords
    }

    public enum TokenizerKind: String, Sendable, Codable {
        case standard
        case ngram
        case morphological  // 日本語等
    }
}
```

### FDBConfiguration

```swift
public struct FDBConfiguration: DataStoreConfiguration, Sendable {
    /// 識別名（オプション、デバッグ用）
    public let name: String?

    /// このConfigurationが担当するモデル（nil = 全モデル）
    public let schema: Schema?

    /// FDB APIバージョン（オプション、ドキュメント用）
    /// 実際のAPIバージョンはグローバルで選択済みである必要がある
    public let apiVersion: Int32?

    /// FDBクラスタファイルURL（SwiftData互換）
    public let url: URL?

    /// インデックス設定（実行時パラメータが必要なインデックス用）
    public let indexConfigurations: [any IndexConfiguration]

    public init(
        name: String? = nil,
        schema: Schema? = nil,
        apiVersion: Int32? = nil,
        url: URL? = nil,
        indexConfigurations: [any IndexConfiguration] = []
    ) {
        self.name = name
        self.schema = schema
        self.apiVersion = apiVersion
        self.url = url
        self.indexConfigurations = indexConfigurations
    }
}
```

**Note**: `isStoredInMemoryOnly` と `allowsSave` は削除されました。
- FDBはサーバーサイドフレームワークであり、テストにはFDBテストクラスタを使用します
- `allowsSave` の制御は `DataStore.save()` の実装に依存し、保証されません

### FDBContainer

```swift
public final class FDBContainer: Sendable {
    /// 全モデルのスキーマ
    public let schema: Schema

    /// ストレージ設定
    public let configurations: [FDBConfiguration]

    /// マイグレーション
    public let migrations: [Migration]

    /// インデックス設定（全Configurationから集約）
    /// キー: indexName, 値: 設定の配列（複数言語対応等のため）
    public let indexConfigurations: [String: [any IndexConfiguration]]

    /// DataStore（FDBDataStoreがデフォルト）
    public let dataStore: any DataStore

    /// メインコンテキスト
    @MainActor public var mainContext: FDBContext { get }

    // MARK: - Initialization

    /// 詳細初期化（SwiftData互換API）
    public init(
        for schema: Schema,
        configurations: [FDBConfiguration] = [],
        migrations: [Migration] = [],
        directoryLayer: DirectoryLayer? = nil,
        dataStore: (any DataStore)? = nil
    ) throws {
        // 1. スキーマが空でないことを検証
        // 2. configuration.schemaがmain schemaのサブセットであることを検証
        // 3. IndexConfiguration集約（同一indexNameは配列にまとめる）
        self.indexConfigurations = Self.aggregateIndexConfigurations(from: configurations)
        // 4. IndexConfigurationがschema内のモデルを参照していることを検証
        try Self.validateIndexConfigurations(
            indexConfigurations: self.indexConfigurations,
            schema: schema
        )
    }

    /// インデックス設定を取得（単一設定用）
    public func indexConfiguration<C: IndexConfiguration>(
        for indexName: String,
        as type: C.Type
    ) -> C? {
        return indexConfigurations[indexName]?.first as? C
    }

    /// インデックス設定を全て取得（複数設定用：多言語全文検索等）
    public func indexConfigurations<C: IndexConfiguration>(
        for indexName: String,
        as type: C.Type
    ) -> [C] {
        return indexConfigurations[indexName]?.compactMap { $0 as? C } ?? []
    }
}
```

---

## 設定フローの全体像

### 1. モデル定義（マクロ時）

```swift
@Persistable
struct Document {
    #Index<Document>([\.embedding], type: VectorIndexKind())
    var embedding: [Float]
}

@Persistable
struct Article {
    #Index<Article>([\.content], type: FullTextIndexKind())
    var content: String
}
```

### 2. Container初期化（実行時）

```swift
let config = FDBConfiguration(
    indexConfigurations: [
        // ベクターインデックス：単一設定
        VectorIndexConfiguration<Document>(
            keyPath: \.embedding,
            dimensions: 1536,
            hnswParameters: .init(M: 16, efConstruction: 200, efSearch: 50),
            loadIntoMemory: true
        ),
        // 全文検索インデックス：複数言語設定
        FullTextIndexConfiguration<Article>(
            keyPath: \.content,
            language: "ja",
            tokenizer: .morphological
        ),
        FullTextIndexConfiguration<Article>(
            keyPath: \.content,
            language: "en",
            tokenizer: .standard
        )
    ]
)

let container = try FDBContainer(
    for: schema,
    configurations: [config]
)
```

### 3. IndexMaintainer作成と設定適用（上位レイヤー）

```swift
// EntityIndexBuilder または IndexManager (fdb-record-layer等)
func buildMaintainers<Item: Persistable>(
    for entity: Item.Type,
    container: FDBContainer
) -> [any IndexMaintainer<Item>] {

    var maintainers: [any IndexMaintainer<Item>] = []

    for descriptor in Item.indexDescriptors {
        // 1. IndexKindMaintainableでMaintainer作成
        guard let maintainable = descriptor.kind as? IndexKindMaintainable else {
            continue
        }

        let index = Index(from: descriptor, itemType: Item.persistableType)
        var maintainer = maintainable.makeIndexMaintainer(
            index: index,
            subspace: indexSubspace,
            idExpression: idExpression
        )

        // 2. IndexConfigurationがあれば適用
        let indexName = descriptor.name  // e.g., "Article_content"

        if let configurable = maintainer as? any IndexConfigurationApplicable {
            // 単一設定の場合
            if let config = container.indexConfiguration(
                for: indexName,
                as: type(of: configurable).Configuration.self
            ) {
                configurable.apply(configuration: config)
            }
        }

        // 複数設定の場合（全文検索の多言語対応等）
        if let multiConfigurable = maintainer as? any MultiIndexConfigurationApplicable {
            let configs = container.indexConfigurations(
                for: indexName,
                as: type(of: multiConfigurable).Configuration.self
            )
            multiConfigurable.apply(configurations: configs)
        }

        maintainers.append(maintainer)
    }

    return maintainers
}
```

### 4. 設定の流れ図

```
┌─────────────────────────────────────────────────────────────────┐
│                         マクロ時                                  │
│  @Persistable + #Index<T>([\.field], type: SomeIndexKind())     │
│                            ↓                                     │
│                    IndexDescriptor                               │
│                  (name, keyPaths, kind)                          │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Container初期化時                            │
│  FDBConfiguration(indexConfigurations: [...])                   │
│                            ↓                                     │
│              FDBContainer.indexConfigurations                    │
│            [indexName: [any IndexConfiguration]]                 │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│                  IndexMaintainer作成時（上位レイヤー）             │
│  1. IndexKindMaintainable.makeIndexMaintainer()                 │
│  2. IndexConfigurationApplicable.apply(configuration:)          │
│                            ↓                                     │
│              設定済みIndexMaintainer                              │
│         (HNSWパラメータ、言語設定等が適用済み)                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 使用例

### 基本（全モデル同一設定）

```swift
let schema = Schema([User.self, Order.self, Product.self])
let container = try FDBContainer(for: schema)
```

### モデル別設定

```swift
let schema = Schema([User.self, Order.self, Product.self])

let container = try FDBContainer(
    for: schema,
    configurations: [
        // User, Order を1つの設定で管理
        FDBConfiguration(
            name: "main",
            schema: Schema([User.self, Order.self])
        ),
        // Product を別の設定で管理
        FDBConfiguration(
            name: "products",
            schema: Schema([Product.self])
        )
    ]
)
```

**Note**: `isStoredInMemoryOnly` は削除されました。テスト用途にはFDBテストクラスタまたはカスタムDataStoreを使用してください。

### ベクターインデックス付き

```swift
@Persistable
struct Document {
    #Index<Document>([\.embedding], type: VectorIndexKind())
    var title: String
    var embedding: [Float]
}

let schema = Schema([Document.self])

let container = try FDBContainer(
    for: schema,
    configurations: [
        FDBConfiguration(
            indexConfigurations: [
                VectorIndexConfiguration(
                    indexName: "Document_embedding",
                    dimensions: 1536,
                    hnswParameters: HNSWParameters(
                        M: 16,
                        efConstruction: 200,
                        efSearch: 50,
                        distanceMetric: .cosine
                    ),
                    loadIntoMemory: true
                )
            ]
        )
    ]
)
```

### 全文検索付き

```swift
@Persistable
struct Article {
    #Index<Article>([\.content], type: FullTextIndexKind())
    var title: String
    var content: String
}

let container = try FDBContainer(
    for: schema,
    configurations: [
        FDBConfiguration(
            indexConfigurations: [
                FullTextIndexConfiguration(
                    indexName: "Article_content",
                    language: "ja",
                    tokenizer: .morphological,
                    removeStopWords: true
                )
            ]
        )
    ]
)
```

### カスタムクラスタファイル

```swift
let container = try FDBContainer(
    for: schema,
    configurations: [
        FDBConfiguration(
            url: URL(filePath: "/etc/foundationdb/replica.cluster")
        )
    ]
)
```

**Note**: `allowsSave` は削除されました。読み取り専用モードが必要な場合は、カスタムDataStoreを実装してください。

---

## 検証ルール

### Container初期化時

1. **スキーマ整合性**: Configurationのschemaがmain schemaのサブセットであること
2. **モデル存在検証**: IndexConfigurationのmodelTypeNameがschema内に存在すること
3. **IndexConfiguration検証**: indexNameがschema内のインデックスに存在すること
4. **IndexKind一致検証**: IndexConfigurationのkindIdentifierがIndexKindのidentifierと一致すること

```swift
// 検証例（実装済み: FDBContainer.validateIndexConfigurations）
private static func validateIndexConfigurations(
    indexConfigurations: [String: [any IndexConfiguration]],  // 複数設定対応
    schema: Schema
) throws {
    let schemaEntityNames = Set(schema.entities.map(\.name))

    for (indexName, configs) in indexConfigurations {
        for config in configs {
            // 1. モデルがスキーマに存在するか
            let modelTypeName = config.modelTypeName
            guard schemaEntityNames.contains(modelTypeName) else {
                throw IndexConfigurationError.invalidConfiguration(
                    indexName: indexName,
                    reason: "Model '\(modelTypeName)' is not defined in the schema"
                )
            }

            // 2. インデックスが存在するか
            guard let descriptor = schema.indexDescriptor(named: indexName) else {
                throw IndexConfigurationError.unknownIndex(indexName: indexName)
            }

            // 3. IndexKindが一致するか
            let descriptorKindIdentifier = type(of: descriptor.kind).identifier
            let configKindIdentifier = type(of: config).kindIdentifier
            guard descriptorKindIdentifier == configKindIdentifier else {
                throw IndexConfigurationError.indexKindMismatch(
                    indexName: indexName,
                    expected: descriptorKindIdentifier,
                    actual: configKindIdentifier
                )
            }
        }
    }
}
```

---

## 未決定事項

### 1. Configurationが担当するモデルの決定方法

**案A: schema必須**
```swift
FDBConfiguration(schema: Schema([User.self]))  // 明示必須
```

**案B: schema省略可（デフォルトで残り全部）**
```swift
FDBConfiguration()  // 他で指定されていないモデル全て
```

**推奨**: 案B - 使いやすさを優先

### 2. IndexConfigurationの保存場所

- FDBModel: 全プラットフォームで使用可能（クライアントでも設定を構築可能）
- FDBIndexing: サーバーのみ（設定はサーバー側でのみ使用）

**推奨**: FDBModel - クライアントから設定を送信できるようにする

### 3. メモリストアの実装

~~`isStoredInMemoryOnly: true` の場合の内部実装~~

**決定**: `isStoredInMemoryOnly` は削除されました。
- FDBはサーバーサイドフレームワークであり、テストにはFDBテストクラスタを使用
- 必要な場合はカスタムDataStoreを実装

---

## 次のステップ

1. [ ] 未決定事項の決定
2. [ ] IndexConfiguration プロトコルの実装 (FDBModel)
3. [ ] IndexConfigurationApplicable プロトコルの実装 (FDBIndexing)
4. [ ] FDBConfiguration の修正 (indexConfigurations追加)
5. [ ] FDBContainer 初期化ロジックの修正 (全Configuration使用)
6. [ ] EntityIndexBuilder での設定適用ロジック追加
7. [ ] テストの追加
