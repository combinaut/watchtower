# Watchtower

Execute a callback on a record when a **related** record changes.

Many models derive state from their associations — a search index document, a cached rollup, a denormalized column. When one of those associated records changes, the owner is stale and needs to recompute. Watchtower lets you declare that relationship once and have the recompute fire automatically, **asynchronously**, whenever a contributing record is saved.

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
2. When an observed record is saved, an [`ActiveRecord::Observer`](https://github.com/rails/rails-observers) hook enqueues a `Watchtower::Job` with a small payload describing the change (class, id, changed attributes).
3. The job resolves the **audience** — the owning records affected by the change — and runs the callback on each.

Because step 2 only does an enqueue, the saving request/transaction isn't slowed by the recompute; the work happens in the job.

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

A trigger with no `attributes` fires on any change. Triggers always fire on destruction regardless of the watched attributes.

### Callbacks

```ruby
watches association: :books, callback: :reindex!                 # method on the affected record
watches association: :books, callback: ->(author) { author.reindex! }  # proc, passed the record
```

## Gating triggers

`enabled:` lets you switch a specific trigger off for the dynamic extent of a block — useful around bulk operations that would otherwise fire the callback for every touched row, when a single batch recompute (or a periodic full rebuild) is cheaper.

```ruby
class Author < ApplicationRecord
  watches association: :books, callback: :reindex!, enabled: -> { Reindexing.enabled? }
end

# A bulk import that rewrites thousands of books, without a reindex per row:
Reindexing.without { importer.run }
```

The key detail is **when** the predicate is evaluated. Callbacks run asynchronously, so a thread-local set inside the block would be long gone by the time the job runs. Watchtower instead evaluates `enabled:` **inline, in the saving thread**, and carries the decision into the job:

- The observer evaluates each matching trigger's `enabled:` predicate when the record saves, and enqueues only the triggers that pass — recording any suppressed triggers' keys in the job payload. If every matching trigger is suppressed, no job is enqueued at all.
- The job honors that recorded decision; it does not re-evaluate the predicate.

So a trigger gated off inside a block stays off for saves made in that block, while other triggers on the same record (e.g. a different model's `watches` on the same class) are unaffected. Triggers without `enabled:` are always enabled, so existing triggers behave exactly as before.

A predicate may be a no-arg `Proc` (a context check, as above), a one-arg `Proc` (passed the changed record, for per-record gating), or a `Symbol`/`String` sent to the changed record (e.g. `enabled: :indexable?`).

## Asynchronous processing

Callbacks run in `Watchtower::Job`, an `ActiveJob`. It uses the application's default queue adapter (the `:async` adapter in development, so a single save doesn't spin up Delayed Job). Configure the queue/adapter as you would any other job.

## Caveats

- **Saves only.** The observer hooks `after_save` (create/update). Hard `destroy` is not observed — a destroyed row can't be reached by the audience join anyway. Use a soft-delete that saves the record if you need destruction to fire a trigger.
- **STI.** The change payload identifies the record by `base_class`, so triggers are matched against the base class of an STI hierarchy.

## Development

```bash
bin/setup          # install dependencies
bundle exec rspec  # run the test suite
bundle exec rubocop
```

The suite boots a dummy Rails app (`spec/dummy`) with `Author` / `Book` / `Review` models and exercises the helpers, the observer, and the job.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
