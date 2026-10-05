# Watchtower

Run a callback on a record whenever one of its associated records is added, changed or removed.

Models often keep state derived from their associations, e.g. a search index document, a cached total or a denormalized column. That state goes out of date when an associated record is **added** to the association, by being created in it or moved into it, **changed** while it stays in it, or **removed** from it, by being moved to another owner or destroyed. Watchtower lets the owner declare that dependency once, and runs the callback that brings the owner up to date whenever one of those changes happens.

```ruby
class Author < ApplicationRecord
  has_many :books

  # Reindex an author when one of their books is added, changed or removed.
  watches association: :books, callback: :reindex!
end
```

If you are looking to react to a record's own changes, e.g. setting a book's slug from its title, the record's own callbacks will serve you better. Watchtower is for the owners on the other side of an association.

Beyond that, a trigger can

- run its callback in a background job, or inline in the thread that made the change (see [Running inline](#running-inline))
- run once when the transaction commits, for all of a record's changes combined, or once for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires))
- be switched off for the extent of a block, with a predicate read when it fires (see [Gating triggers](#gating-triggers))
- wrap all the callbacks of one change in a block, e.g. to send them as one batch (see [Wrapping the callbacks](#wrapping-the-callbacks))

## How it works

1. `watches(...)` registers a **trigger**, and tells Watchtower to observe the records of the association it names (`association:`), or the class an `affects:` scope reads (`class:`).
2. When one of those records is added, changed or removed, an [`ActiveRecord::Observer`](https://github.com/rails/rails-observers) hook records the change (the record's class, id and changed attributes, and the foreign keys that tied it to its owners before it moved or was destroyed). By default Watchtower runs one callback for all of a record's changes once the transaction commits. A trigger can instead run one callback for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)).
3. Watchtower finds the **audience**, the owners the change affects, and runs the callback on each.

## Installation

```ruby
gem "watchtower", git: "git@github.com:combinaut/watchtower.git"
```

The engine adds `watches` to every model and registers the observer, so no initializer is needed. Watchtower requires Rails 7.2 or newer.

## Usage

`watches` is available on every model. It accepts the following options:

| Option | Description |
| --- | --- |
| `association:` | A `has_many` / `belongs_to` on the observing model. When one of its records is added, changed or removed, the owners it reaches are the audience. |
| `affects:` | An alternative to `association:`, a `Proc` (given the associated record) or method name returning the relation of owners to run on. Use it when the audience can't be expressed as a single association join. Requires `class:`. |
| `class:` | The observed class. Inferred from `association:`. Give it when using `affects:`, or when the association isn't defined yet at declaration time. |
| `callback:` | What to run on each affected record. A `Symbol`/`String` is sent to the record; a `Proc` is called (passed the record if it takes an argument). |
| `attribute:` / `attributes:` | Only fire when one of these attributes changed. Omit to fire on any change. |
| `includes:` | Associations to eager-load on the audience before running the callback (avoids N+1 in the callback). |
| `enabled:` | A predicate gating the trigger (see [Gating triggers](#gating-triggers)). Defaults to always enabled. |
| `inline:` | Run the callback in the thread that made the change instead of in a job (see [Running inline](#running-inline)). Defaults to `false`. |
| `around:` | A block the callbacks of a change run inside (see [Wrapping the callbacks](#wrapping-the-callbacks)). |
| `at:` | When the trigger fires, `:commit` once the transaction commits or `:save` at each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). Defaults to `:commit`. |

### Audience: `association:` vs `affects:`

With `association:`, Watchtower finds owners by joining that association to the associated record.

```ruby
# A review changing reindexes the author it belongs to (Author has_many :reviews, through: :books)
watches association: :reviews, callback: :reindex!
```

When the relationship isn't a single association join, return the owners yourself with `affects:`.

```ruby
watches class: "Book",
        affects: ->(book) { Author.where(id: book.author_id) },
        callback: :reindex!
```

### Filtering by attribute

Fire only when specific columns change.

```ruby
# Reindex only when a book's title changes, not on every book save.
watches association: :books, attribute: :title, callback: :reindex!
```

A trigger with no `attributes` fires on any change. A trigger always fires when a record is added or removed, regardless of the watched attributes (see [Moves and destroys](#moves-and-destroys)).

### Callbacks

```ruby
watches association: :books, callback: :reindex!                 # method on the affected record
watches association: :books, callback: ->(author) { author.reindex! }  # proc, passed the record
```

Several triggers of an observing class that share a callback and run the same way, queued or inline and at the same `at:`, run it once per affected owner.

```ruby
watches association: :books, attribute: :title, callback: :reindex!
watches association: :books, attribute: :genre, callback: :reindex!

book.update!(title: "Persuasion", genre: "Novel")  # reindexes the book's author once, not twice
```

## Moves and destroys

A record removed from an owner, by moving to another owner or being destroyed, leaves an owner behind that the association join no longer reaches. Watchtower runs the callback on that owner too.

- **Moves.** A save that changes the foreign key linking the record to its owners, and for a polymorphic association the type, runs the callback on the owner the record was removed from and the owner it was added to. Moving a `Book` to another `Author` reindexes both.
- **Destroys.** Destroying a record runs the callback on the owners it had.
- **Records an association passes through.** For `has_many :reviews, through: :books`, moving or destroying a `Book` changes an author's reviews without any `Review` saving, so a trigger on `:reviews` also watches `Book`. Only a change to the `Book`'s foreign keys fires it (its `author_id`, or for `has_many :publishers, through: :books`, its `publisher_id`), not every `Book` save. A trigger declared before its association (with `class:`) starts watching the record it passes through the next time the observer reinitializes after the association exists. The observer reinitializes once the application has initialized, and whenever a new trigger watches a class it does not yet observe.

For a queued trigger, the owners before the change are found from the foreign keys the change carries, not queried in the thread that made the change, so a save costs no more reads with a trigger than without one. The one exception is an `affects:` trigger on a destroyed record, whose scope is evaluated at the destroy, since the job can no longer load the record.

## Running inline

`inline: true` runs the callback in the thread that made the change rather than in a job, after the change commits by default, or inside the transaction with `at: :save` (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). Use it when the callback depends on context that thread holds, e.g. a batch being collected or a thread-local mode, or needs to write immediately.

```ruby
watches association: :books, callback: :reindex!, inline: true
```

## Wrapping the callbacks

`around:` wraps the loop that runs the callback. When a change fires the trigger, Watchtower finds every record the change affects and calls the callback on each. `around:` is a `Proc` called once for the change, with a block that runs that whole loop. A queued trigger runs it inside the change's `Watchtower::Job`, and an inline one in the thread that made the change, when the trigger fires. It is never called per record.

That makes it the place to batch what the callbacks do. Here the search index collects the reindexing of every author a change affects, and sends it in one request.

```ruby
watches association: :books,
        callback: :reindex!,
        around: ->(&reindexing) { SearchIndex.batch(&reindexing) }
```

When Book 7 moves from Ada to Grace, the change runs the following.

```ruby
SearchIndex.batch do   # around:, once for the change
  ada.reindex!         # the callback, once per affected author
  grace.reindex!
end                    # SearchIndex.batch sends both here
```

A block inside the callback would instead open and send a batch for every record. Triggers that share an observing class, a callback and an `around:` run the callback once per record inside that one block. Triggers whose `around:` differs run inside their own.

## Choosing when a trigger fires

`at:` sets when a trigger fires, and with it when its `enabled:` is read.

- **`at: :commit` converges** on the committed state. The trigger fires once the transaction commits, once for each record the transaction added, changed or removed, on the owners the record had before the transaction and the owners it has after. Anything in between is skipped, and a change that rolls back fires nothing.
- **`at: :save` follows every step.** The trigger fires as each save or destroy happens, inside the transaction, on the owners the record had before that save and the owners it has when the callback runs.

The owners are plural because a record can have several. A book has one author, but a publisher belongs to every author who has a book it published (`has_many :publishers, through: :books`), so a change to a publisher reaches all of them.

`inline:` sets where the callback runs. The two combine freely.

| | `at: :commit` (default) | `at: :save` |
| --- | --- | --- |
| queued | One job per record added, changed or removed, enqueued once the transaction commits. A rollback enqueues nothing. | One job per save, enqueued inside the transaction. A job backend that stores jobs in the same database (Delayed Job) commits or rolls back the job with the change. |
| `inline: true` | The callback runs once the transaction commits, once per record added, changed or removed. | The callback runs inside the transaction, once per save, so what it writes commits or rolls back with the change. |

Each combination has a use.

**Queued, `at: :commit` (the default).** Best for: updating something outside the database, such as a search index, a cache, or another system's copy of the data. The job sees only committed data, never runs for a change that rolls back, and runs once for a record saved several times in one transaction.

```ruby
# Reindex an author's search document when one of their books changes.
watches association: :books, callback: :reindex!
```

**Inline, `at: :commit`.** Best for: work that the code making the changes collects and finishes itself. A script that rewrites many books opens a batch, the callbacks add each affected author to it, and the script reindexes each author once when it finishes. The callback runs in the script's thread, where it can reach the batch, and only for changes that committed.

```ruby
watches association: :books, callback: :add_to_reindex_batch, inline: true, enabled: -> { ReindexBatch.open? }
```

**Inline, `at: :save`.** Best for: a value on the owner that later steps of the same transaction rely on. Say `authors.latest_published_on` holds the date of each author's latest book, and one transaction adds a book and then selects authors by that date. A callback that fires at the commit would update the column after that query had run. One that fires at the save updates it as the book is saved, so the query sees the new date, and a rollback undoes the update along with the book.

```ruby
watches association: :books, attribute: :published_on, callback: :update_latest_published_on!, inline: true, at: :save
```

**Queued, `at: :save`.** Best for: work that must not be lost, when the queue stores its jobs in the application's database. A queue such as Delayed Job or GoodJob does, so a job enqueued inside the transaction commits or rolls back with the change, and a process that dies just after the commit cannot lose it. That suits keeping another system's copy of each author's book list current, where a lost job leaves it stale until the author's books change again. With a queue outside the database, such as Sidekiq, the job is enqueued even when the transaction rolls back and can run before the change commits, so keep the default.

```ruby
watches association: :books, callback: :notify_storefront!, at: :save
```

A queued `at: :save` trigger depends on Active Job writing the job when `perform_later` is called. Active Job's `enqueue_after_transaction_commit` setting instead holds every enqueue until the surrounding transaction commits, so the trigger's jobs would no longer commit or roll back with the change. So declaring a queued `at: :save` trigger raises `ArgumentError` while that setting is on for `Watchtower::Job`. Watchtower never changes the setting itself, so turn it off for `Watchtower::Job`, or keep the trigger at the commit. The check runs when the trigger is declared, so it misses a setting turned on after the trigger was declared.

```ruby
# config/initializers/watchtower.rb
Rails.application.config.to_prepare do
  # On Rails 7.2, only :never stops the queue adapter from deferring, and `load_defaults 7.2` leaves it to the adapter.
  Watchtower::Job.enqueue_after_transaction_commit = Rails.gem_version < Gem::Version.new("8.0") ? :never : false
end
```

### What fires, and how often

A trigger that fires at the commit fires once for each record the transaction added, changed or removed, on all of its saves and destroys merged into one, even when they went through several instances of the record. Rails' transaction callbacks (`current_transaction.after_commit`) deliver it once the outermost transaction commits, leaving out every save that rolled back, including one inside a savepoint (`requires_new: true`) that rolled back. A trigger that fires at the save fires once per save. Either way, each time a trigger fires, its callback runs once for each owner the change reaches, however many of the callback's triggers the change matches among those that run the same way (see [Callbacks](#callbacks)). A change reaches the owners the record had before it and the owners the record has when the callback runs, which are read from the database.

| In one transaction | `at: :commit` | `at: :save` |
| --- | --- | --- |
| A book's `title` is saved twice | `reindex!` runs once on its author, after the commit | `reindex!` runs twice on its author, once for each save |
| A book moves from Ada to Grace, then to Hedy | the callback runs on Ada and Hedy. Grace held the book only inside the transaction, so nothing she derives changed | inline, the callback runs on Ada and Grace at the first save, and on Grace and Hedy at the second. Queued, each save's job runs on the owner before that save and on the owner when the job runs. With a queue in the application's database that is after the commit, so Ada and Hedy, then Grace and Hedy. A queue outside the database can run a job before the commit, when its connection still sees an earlier owner |
| The transaction rolls back | nothing runs | inline callbacks have already run, and only their database writes are undone; queued jobs are rolled back only by a queue in the same database |

## Gating triggers

`enabled:` lets you switch a specific trigger off for the dynamic extent of a block. That is useful around bulk operations that would otherwise fire the callback for every touched row, when a single batch recompute, or a periodic full rebuild, is cheaper.

```ruby
class Author < ApplicationRecord
  watches association: :books, callback: :reindex!, enabled: -> { Reindexing.enabled? }
end

# Rewrite thousands of books without a reindex per book, then reindex every author once:
Reindexing.without { Book.find_each { |book| book.update!(title: book.title.strip) } }
Author.find_each(&:reindex!)
```

The key detail is **when** the predicate is evaluated. A queued trigger's callback runs in a job, so a thread-local set inside the block would be long gone by the time the job runs. Watchtower instead evaluates `enabled:` **when the trigger fires, in the thread that made the change**, i.e. as the change commits, or for an `at: :save` trigger as the record saves. It carries a queued trigger's decision into the job.

- The observer evaluates each matching trigger's `enabled:` predicate as it fires. It runs the inline triggers that pass, and enqueues the queued triggers that pass, recording the other queued triggers' keys in the job payload as suppressed. If no matching queued trigger passes, no job is enqueued at all.
- The job honors that recorded decision; it does not re-evaluate the predicate.

So a trigger gated off inside a block stays off for changes that fire in that block, while other triggers on the same record (e.g. a different model's `watches` on the same class) are unaffected. A block opened inside a transaction does not cover the transaction's commit, so a change saved in the block and committed after it is gated by the context at the commit, unless its trigger fires `at: :save`. Triggers without `enabled:` are always enabled.

A predicate may be a no-arg `Proc` (a context check, as above), a one-arg `Proc` (passed the associated record, for per-record gating), or a `Symbol`/`String` sent to the associated record (e.g. `enabled: :indexable?`).

## Asynchronous processing

Queued callbacks run in `Watchtower::Job`, an `ActiveJob`, so the change that fired them is not slowed by the work. It uses the application's default queue adapter (the `:async` adapter in development, so a single save doesn't spin up Delayed Job). Configure the queue and adapter as you would any other job. An inline trigger runs its callback in the thread that made the change instead (see [Running inline](#running-inline)).

## Caveats

- **Nested through associations.** When an association's source is itself a `has_many :through`, Watchtower watches the association's own records and the records on its `through:` side, but not the records inside the source. With `has_many :review_comments, through: :books` on `Author`, where `Book` has `has_many :review_comments, through: :reviews, source: :comments`, it watches the comments and the books, not the reviews. https://github.com/combinaut/watchtower/issues/15 tracks the gaps.

  | Change | Reaches |
  | --- | --- |
  | A comment is saved | its author |
  | A book moves to another author | both authors |
  | A book is destroyed | its author |
  | A comment moves to a review on another book | only the new author |
  | A comment is destroyed | no author |
  | A review moves to another book, or is destroyed | no author |
- **`affects:` on a move.** An `affects:` scope is evaluated on the record as it is when the callback runs, so it reaches only the current owners.
- **STI.** The change payload identifies the record by `base_class`, so triggers are matched against the base class of an STI hierarchy.
- **Saves through an out-of-date instance.** A move's previous owner is the one the saving instance last loaded or saved, not the one stored in the database, so a save costs no extra read. When a book is loaded under Ada, another process moves it to Grace and commits, and the first instance then moves it to Hedy, that save reports Ada as the previous owner, and Grace, who held the book, is not reached. The save also overwrites a change it never saw, so reload an instance before saving it after another may have written the row.

## Development

```bash
bin/setup                              # install dependencies
bundle exec rake                       # run the test suite (test/ and spec/)
bundle exec appraisal rails-7.2 rake   # against Rails 7.2; rails-8.0 likewise
bundle exec rubocop
```

CI runs the suite against every Rails version Watchtower supports, the `Gemfile`'s and each one in `Appraisals`. The suite boots a dummy Rails app (`spec/dummy`) with `Author` / `Book` / `Review` / `Publisher` / `Comment` models and exercises the helpers, the observer, and the job.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
