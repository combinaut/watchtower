# Watchtower

Execute a callback on a record when a **related** record changes.

Many models derive state from their associations — a search index document, a cached rollup, a denormalized column. When one of those associated records changes, the owner is stale and needs to recompute. Watchtower lets you declare that relationship once and have the recompute fire automatically, **asynchronously** by default, whenever a contributing record is saved or destroyed.

```ruby
class Author < ApplicationRecord
  has_many :books

  # When any of an author's books changes, reindex that author.
  watches association: :books, callback: :reindex!
end
```

Save a `Book` and the owning `Author#reindex!` runs in a background job — no `after_save` hooks scattered across `Book`, no manual bookkeeping.

## How it works

1. `watches(...)` registers a **trigger** and tells Watchtower to observe the changed class (the `Book` in the example above).
2. When an observed record is saved or destroyed, an [`ActiveRecord::Observer`](https://github.com/rails/rails-observers) hook records the change (class, id, changed attributes, and the foreign keys that tied the record to its owners before a move or destroy). When the transaction commits, it enqueues one `Watchtower::Job` carrying the change. A transaction that rolls back enqueues nothing, and a record saved several times in one transaction enqueues one job.
3. The job resolves the **audience** — the owning records affected by the change — and runs the callback on each.

Because step 2 only does an enqueue, the saving request/transaction isn't slowed by the recompute; the work happens in the job. An [inline trigger](#running-inline) runs the callback after the commit instead.

## Installation

```ruby
gem "watchtower", git: "git@github.com:combinaut/watchtower.git"
```

The engine includes the DSL into `ActiveRecord::Base` and registers the observer automatically. No initializer required.

## Usage

`watches` is available on every model. It accepts the following options:

| Option | Description |
| --- | --- |
| `association:` | A `has_many` / `belongs_to` on the observing model. When a record in that association changes, the owners reachable through it are the audience. |
| `affects:` | An alternative to `association:` — a `Proc` (given the changed record) or method name returning the relation/scope of affected records. Use it when the audience can't be expressed as a single association join. Requires `class:`. |
| `class:` | The observed class. Inferred from `association:`; specify it explicitly when using `affects:` (or when the association isn't defined yet at declaration time). |
| `callback:` | What to run on each affected record. A `Symbol`/`String` is sent to the record; a `Proc` is called (passed the record if it takes an argument). |
| `attribute:` / `attributes:` | Only fire when one of these attributes changed. Omit to fire on any change. |
| `includes:` | Associations to eager-load on the audience before running the callback (avoids N+1 in the callback). |
| `enabled:` | A predicate gating the trigger — see [Gating triggers](#gating-triggers). Defaults to always-enabled. |
| `inline:` | Run the callback in the saving thread instead of in a job — see [Running inline](#running-inline). Defaults to `false`. |
| `around:` | A block the callbacks of a change run inside — see [Wrapping the callbacks](#wrapping-the-callbacks). |
| `at:` | When the trigger fires: `:commit`, once the change's transaction commits, or `:save`, as the record is saved or destroyed — see [Choosing when a trigger fires](#choosing-when-a-trigger-fires). Defaults to `:commit`. |

### Audience: `association:` vs `affects:`

With `association:`, Watchtower finds owners by joining that association to the changed record:

```ruby
# A review changing reindexes the author it belongs to (Author has_many :reviews, through: :books)
watches association: :reviews, callback: :reindex!
```

When the relationship isn't a single association join, return the scope yourself with `affects:`:

```ruby
watches class: "Book",
        affects: ->(book) { Author.where(id: book.author_id) },
        callback: :reindex!
```

### Filtering by attribute

Fire only when specific columns change:

```ruby
# Reindex only when a book's title changes, not on every book save.
watches association: :books, attribute: :title, callback: :reindex!
```

A trigger with no `attributes` fires on any change. Triggers always fire on a destroy, and on a [move](#moves-and-destroys), regardless of the watched attributes.

### Callbacks

```ruby
watches association: :books, callback: :reindex!                 # method on the affected record
watches association: :books, callback: ->(author) { author.reindex! }  # proc, passed the record
```

Several triggers of an observing class that share a callback and run the same way (queued or inline) run it once per affected record, so an `Author` watching both its books' `title` and their `genre` is reindexed once when a book changes both.

## Moves and destroys

A record that moves to another owner, or is destroyed, leaves an owner behind that the association join no longer reaches. Watchtower runs the callback on that owner too:

- **Moves.** A save that changes the foreign key linking the record to its owners (and, for a polymorphic association, the type) runs the callback on the owner before and the owner after. Moving a `Book` to another `Author` reindexes both.
- **Destroys.** Destroying a record runs the callback on the owners it had.
- **Records an association passes through.** For `has_many :reviews, through: :books`, moving or destroying a `Book` changes an author's reviews without any `Review` saving, so a trigger on `:reviews` also watches `Book`. Only a change to the `Book`'s foreign keys fires it (its `author_id`, or for `has_many :publishers, through: :books`, its `publisher_id`), not every `Book` save. A trigger declared before its association (with `class:`) starts watching the record it passes through the next time the observer reinitializes after the association exists. The observer reinitializes once the application has initialized, and whenever a new trigger watches a class it does not yet observe.

For a queued trigger, the owners before the change are found from the foreign keys the change carries, not queried in the saving thread, so a save costs no more reads with a trigger than without one. The one exception is an `affects:` trigger on a destroyed record, whose scope is evaluated at the destroy, since the job can no longer load the record.

## Running inline

`inline: true` runs the callback in the saving thread, after the change commits (or inside the transaction with `at: :save`), rather than in a job. Use it when the callback depends on context the saving thread holds — a batch being collected, a thread-local mode — or needs to write immediately. A transaction that rolls back runs nothing, and a savepoint that rolls back (`requires_new: true`) drops only its own changes. A record saved several times in one transaction runs the callback once, on the owners it had before the transaction and those it has after.

```ruby
watches association: :books, callback: :reindex!, inline: true
```

## Wrapping the callbacks

`around:` wraps the loop that runs the callback. When a change fires the trigger, Watchtower finds every record the change affects and calls the callback on each. `around:` is a `Proc` called once for the change, with a block that runs that whole loop. A queued trigger runs it inside the change's `Watchtower::Job`, and an inline one in the saving thread after the commit. It is never called per record.

That makes it the place to batch what the callbacks do. Here the search index collects the reindexing of every author a change affects, and sends it in one request:

```ruby
watches association: :books,
        callback: :reindex!,
        around: ->(&reindexing) { SearchIndex.batch(&reindexing) }
```

When Book 7 moves from Ada to Grace, the change runs:

```ruby
SearchIndex.batch do   # around:, once for the change
  ada.reindex!         # the callback, once per affected author
  grace.reindex!
end                    # SearchIndex.batch sends both here
```

A block inside the callback would instead open and send a batch for every record. Triggers that share an observing class, a callback and an `around:` run the callback once per record inside that one block. Triggers whose `around:` differs run inside their own.

## Choosing when a trigger fires

`at:` sets when a trigger fires, and with it when its `enabled:` is read. `inline:` sets where its callback runs. They combine freely:

| | `at: :commit` (default) | `at: :save` |
| --- | --- | --- |
| queued | One job per committed transaction, enqueued after the commit. A rollback enqueues nothing. | One job per save, enqueued inside the transaction. A job backend that stores jobs in the same database (Delayed Job) commits or rolls back the job with the change. |
| `inline: true` | The callback runs after the commit, once for every change the transaction made to the record. | The callback runs inside the transaction, once per save, so what it writes commits or rolls back with the change. |

Each combination has a use:

**Queued, `at: :commit` (the default): refresh something outside the database.** A search index, a cache or a sync to another system should see only committed data, and should not run for a change that rolls back. A transaction that saves a record several times enqueues one job.

```ruby
# Reindex an author's search document when one of their books changes.
watches association: :books, callback: :reindex!
```

**Inline, `at: :commit`: collect the work in the caller's thread.** A bulk import that wants each affected owner recomputed once, after the import, opens a batch around the import and lets the callbacks add to it.

```ruby
watches association: :books, callback: :add_to_reindex_batch, inline: true, enabled: -> { ReindexBatch.open? }
```

**Inline, `at: :save`: keep a stored value in the same transaction as its source.** A column on the owner that a later step of the same transaction reads, or that must roll back with the change, is updated before the transaction moves on.

```ruby
# An import step later in the same transaction checks each author's latest publication date.
watches association: :books, attribute: :published_on, callback: :update_latest_published_on!, inline: true, at: :save
```

**Queued, `at: :save`: never lose the job, with a queue in the application's database.** Delayed Job, GoodJob and Solid Queue store jobs in the application's database, so a job enqueued inside the transaction commits or rolls back with the change, and a process that dies just after the commit cannot lose it. That suits work that must happen for every change, such as a sync to a CRM. With a queue outside the database, such as Sidekiq, the job is enqueued even when the transaction rolls back and can run before the change commits, so keep the default.

```ruby
watches association: :books, callback: :sync_to_crm, at: :save
```

A trigger that fires at the commit sees the change after every save in its transaction, so a record saved several times fires once, on the owners it had before the transaction and those it has after. A trigger that fires at the save sees each save on its own.

## Gating triggers

`enabled:` lets you switch a specific trigger off for the dynamic extent of a block — useful around bulk operations that would otherwise fire the callback for every touched row, when a single batch recompute (or a periodic full rebuild) is cheaper.

```ruby
class Author < ApplicationRecord
  watches association: :books, callback: :reindex!, enabled: -> { Reindexing.enabled? }
end

# A bulk import that rewrites thousands of books, without a reindex per row:
Reindexing.without { importer.run }
```

The key detail is **when** the predicate is evaluated. A queued trigger's callback runs in a job, so a thread-local set inside the block would be long gone by the time the job runs. Watchtower instead evaluates `enabled:` **when the trigger fires, in the thread that made the change**: as the change commits, or for an `at: :save` trigger as the record saves. It carries a queued trigger's decision into the job:

- The observer evaluates each matching trigger's `enabled:` predicate as it fires. It runs the inline triggers that pass, and enqueues the queued triggers that pass, recording the other triggers' keys in the job payload as suppressed. If no matching queued trigger passes, no job is enqueued at all.
- The job honors that recorded decision; it does not re-evaluate the predicate.

So a trigger gated off inside a block stays off for changes that fire in that block, while other triggers on the same record (e.g. a different model's `watches` on the same class) are unaffected. A block opened inside a transaction does not cover the transaction's commit: a change saved in the block and committed after it is gated by the context at the commit, unless its trigger fires `at: :save`. Triggers without `enabled:` are always enabled.

A predicate may be a no-arg `Proc` (a context check, as above), a one-arg `Proc` (passed the changed record, for per-record gating), or a `Symbol`/`String` sent to the changed record (e.g. `enabled: :indexable?`).

## Asynchronous processing

Queued callbacks run in `Watchtower::Job`, an `ActiveJob`. It uses the application's default queue adapter (the `:async` adapter in development, so a single save doesn't spin up Delayed Job). Configure the queue/adapter as you would any other job. An inline trigger runs its callback in the saving thread instead (see [Running inline](#running-inline)).

## Caveats

- **Nested through associations.** For an association through another whose source is itself a through association, only the first record it passes through is watched, and a move of the association's own records reaches only their current owners.
- **`affects:` on a move.** An `affects:` scope is evaluated on the record as it is when the callback runs, so it reaches only the current owners.
- **STI.** The change payload identifies the record by `base_class`, so triggers are matched against the base class of an STI hierarchy.

## Development

```bash
bin/setup          # install dependencies
bundle exec rspec  # run the test suite
bundle exec rubocop
```

The suite boots a dummy Rails app (`spec/dummy`) with `Author` / `Book` / `Review` / `Publisher` / `Comment` models and exercises the helpers, the observer, and the job.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
