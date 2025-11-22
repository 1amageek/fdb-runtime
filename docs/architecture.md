# FDBRuntime アーキテクチャ設計

**Last Updated**: 2025-01-21

## 概要

FDBRuntime は、FoundationDB 上で複数のデータモデル層をサポートするための抽象基盤層です。型非依存の共通ストア（FDBStore）とプロトコル定義（IndexMaintainer, RecordAccess）を提供し、各上位レイヤーで具体的な実装を行います。

## 設計目標

1. **単一ストアの共通使用**: すべてのデータモデル層で FDBStore を共通使用（型非依存）
2. **プロトコル層**: FDBRuntime はインターフェース定義のみ、実装は各上位レイヤー
3. **複数データモデル**: Record、Document、Vector、Graph など、異なるデータモデルを統一基盤でサポート
4. **責任分離**: メタデータ、コア、抽象基盤、データモデル層の明確な分離
5. **拡張性**: 新しいデータモデル層を追加可能なプロトコルベース設計

## アーキテクチャ全体図

```
┌─────────────────────────────────────────────────────────┐
│                   fdb-indexing                           │
│  役割: インデックスメタデータ定義（プロトコルのみ）          │
│  依存: Swift stdlib + Foundation                         │
│  プラットフォーム: iOS, macOS, Linux (全プラットフォーム)    │
│                                                          │
│  ✅ IndexKindProtocol                                    │
│  ✅ IndexDescriptor                                      │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│              fdb-runtime/FDBCore                         │
│  役割: FDB非依存のコア機能 (Server-Client共通)             │
│  依存: Swift stdlib + Foundation + fdb-indexing          │
│  プラットフォーム: iOS, macOS, Linux (全プラットフォーム)    │
│                                                          │
│  ✅ Recordableプロトコル (FDB非依存)                      │
│  ✅ @Recordableマクロ (FDBCoreMacros)                    │
│  ✅ #PrimaryKey, #Index, #Directory マクロ                │
│  ✅ EnumMetadata                                         │
│  ✅ Codable準拠                                          │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│             fdb-runtime/FDBRuntime                       │
│  役割: 抽象基盤層（プロトコル定義 + 共通実装）              │
│  依存: FDBCore + FoundationDB (fdb-swift-bindings)       │
│  プラットフォーム: macOS, Linux (Server専用)               │
│                                                          │
│  【共通実装】                                             │
│  ✅ FDBStore - 型非依存ストア（全レイヤーで共通使用）       │
│  ✅ FDBContainer - コンテナ管理                          │
│  ✅ FDBContext - 変更追跡                                │
│  ✅ IndexManager - Index登録・管理システム                │
│                                                          │
│  【プロトコル定義のみ】                                   │
│  ✅ IndexMaintainer<Record> protocol                     │
│  ✅ RecordAccess<Record> protocol                        │
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
│ RecordAccess    │ │DocAccess    │ │API)      │ │API)      │
│ 実装            │ │実装         │ │          │ │          │
│                 │ │             │ │Vector    │ │Graph     │
│ IndexMaintainer │ │IndexMaint   │ │Access実装│ │Access実装│
│ 実装群:         │ │実装群       │ │          │ │          │
│ - ValueIndex    │ │- DocIndex   │ │Vector    │ │Graph     │
│ - CountIndex    │ │- TextSearch │ │IndexMaint│ │IndexMaint│
│ - VectorIndex   │ │- Aggregation│ │実装      │ │実装      │
│ - etc.          │ │             │ │          │ │          │
│                 │ │             │ │          │ │          │
│ QueryPlanner    │ │QueryEngine  │ │Similarity│ │Traversal │
│                 │ │             │ │Search    │ │Queries   │
│                 │ │             │ │          │ │          │
│ Recordable型    │ │Document型   │ │Vector型  │ │Graph型   │
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
    public func save(data: Data, for recordName: String, primaryKey: any TupleElement, transaction: any TransactionProtocol) throws
    public func load(for recordName: String, primaryKey: any TupleElement, transaction: any TransactionProtocol) async throws -> Data?
    public func delete(for recordName: String, primaryKey: any TupleElement, transaction: any TransactionProtocol) throws
}

// fdb-record-layer: 型安全な拡張
public struct RecordStore<Record: Recordable> {
    private let store: FDBStore

    public func save(_ record: Record) async throws {
        let data = try serialize(record)
        try await store.save(data: data, for: Record.recordName, primaryKey: extractPrimaryKey(record), transaction: tx)
        // IndexMaintainer を呼び出してインデックス更新
    }
}
```

### 決定2: FDBRuntime はプロトコル層

**理由**:
- IndexMaintainer と RecordAccess のプロトコル定義のみを FDBRuntime に配置
- 具体的な実装は各上位レイヤーに配置
- 各データモデル層が独自の実装を提供可能

**利点**:
- 拡張性の向上
- 責任の明確化
- 新しいデータモデル層の追加が容易

**プロトコル定義**:
```swift
// FDBRuntime: プロトコルのみ
public protocol IndexMaintainer<Record>: Sendable {
    associatedtype Record: Sendable

    func updateIndex(oldRecord: Record?, newRecord: Record?, recordAccess: any RecordAccess<Record>, transaction: any TransactionProtocol) async throws
    func scanRecord(_ record: Record, primaryKey: Tuple, recordAccess: any RecordAccess<Record>, transaction: any TransactionProtocol) async throws
}

public protocol RecordAccess<Record>: Sendable {
    associatedtype Record: Sendable

    func recordName(for record: Record) -> String
    func evaluate(record: Record, expression: KeyExpression) throws -> [any TupleElement]
    func extractField(from record: Record, fieldName: String) throws -> [any TupleElement]
    func serialize(_ record: Record) throws -> FDB.Bytes
    func deserialize(_ bytes: FDB.Bytes) throws -> Record
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

## データフロー

### 保存フロー（fdb-record-layer の例）

```
1. User code:
   recordStore.save(user)

2. RecordStore (fdb-record-layer):
   - GenericRecordAccess で user をシリアライズ
   - FDBStore.save(data, "User", primaryKey, transaction)
   - IndexMaintainer 実装群を呼び出し

3. FDBStore (fdb-runtime):
   - Subspace 解決: recordSubspace.subspace("User")
   - Key 生成: subspace.subspace(primaryKey).pack(Tuple())
   - transaction.setValue(data, for: key)

4. IndexMaintainer 実装 (fdb-record-layer):
   - ValueIndexMaintainer.updateIndex(...)
   - IndexSubspace にエントリ作成
```

### 読み取りフロー（fdb-record-layer の例）

```
1. User code:
   let users = try await recordStore.query().where(\.email, .equals, "test@example.com").execute()

2. RecordStore (fdb-record-layer):
   - QueryPlanner でプラン作成（インデックススキャン vs フルスキャン）
   - IndexMaintainer からインデックスエントリ読み取り
   - FDBStore.load(for: "User", primaryKey: pk, transaction: tx)

3. FDBStore (fdb-runtime):
   - Key 生成: recordSubspace.subspace("User").subspace(pk).pack(Tuple())
   - let data = transaction.getValue(for: key)

4. RecordStore (fdb-record-layer):
   - GenericRecordAccess で data をデシリアライズ
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

2. **RecordAccess 実装**: データアクセスロジックを提供
   ```swift
   struct DocumentAccess: RecordAccess {
       typealias Record = Document
       // 実装...
   }
   ```

3. **IndexMaintainer 実装**: インデックス維持ロジックを提供
   ```swift
   struct DocumentIndexMaintainer: IndexMaintainer {
       typealias Record = Document
       // 実装...
   }
   ```

## 各データモデル層の詳細

### fdb-record-layer（レコード層）

**役割**: 構造化レコードの型安全な操作

**実装内容**:
- RecordStore<Record: Recordable> - FDBStore の型安全なラッパー
- GenericRecordAccess<Record: Recordable> - RecordAccess の実装
- IndexMaintainer 実装群（ValueIndexMaintainer, CountIndexMaintainer, etc.）
- QueryPlanner - クエリプラン最適化

### fdb-document-layer（ドキュメント層）

**想定される実装**:
- 柔軟なスキーマレスドキュメント
- JSON/BSON ベースのシリアライズ
- テキスト検索インデックス
- 集約パイプライン

### fdb-vector-layer（ベクトル層）

**想定される実装**:
- 高次元ベクトル埋め込み
- HNSW/IVF インデックス
- 類似度検索（cosine, L2, inner product）
- バッチベクトル操作

### fdb-graph-layer（グラフ層）

**想定される実装**:
- ノード・エッジモデル
- トラバーサルクエリ
- 最短経路探索
- PageRank などのアルゴリズム

## まとめ

FDBRuntime は、複数のデータモデル層を統一基盤でサポートするための抽象基盤層です。型非依存の FDBStore とプロトコル定義により、柔軟で拡張性の高いアーキテクチャを実現しています。

**キーポイント**:
- ✅ **FDBStore は全レイヤーで共通使用**（RecordStore, DocumentStore などは作らない）
- ✅ **FDBRuntime はプロトコル層**（実装は各上位レイヤー）
- ✅ **複数データモデル**（Record, Document, Vector, Graph）をサポート
- ✅ **明確な責任分離**とレイヤー構造
- ✅ **拡張性の高い設計**（新しいデータモデル層を追加可能）

---

**Last Updated**: 2025-01-21
