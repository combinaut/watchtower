# Watchtower

Run a callback on a record whenever one of its associated records is added, changed or removed.

Models often keep state derived from their associations. That state goes out of date when an associated record is **added** to the association (created in it or moved into it), **changed** while it stays in it, or **removed** from it (moved to another owner or destroyed). Watchtower lets the owner declare that dependency once, and runs the callback that brings the owner up to date whenever one of those changes happens.

```ruby
class Author < ApplicationRecord
  has_many :books

  # Reindex an author when one of their books is added, changed or removed.
  watches association: :books, callback: :reindex!
end
```

If you are looking to react to a record's own changes, its own callbacks will serve you better. Watchtower is for the owners on the other side of an association.

A trigger can also:

- run its callback in a background job, or inline in the thread that made the change (see [Running inline](#running-inline))
- run once when the transaction commits, for all of a record's changes combined, or once for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires))
- be switched off for the extent of a block, with a predicate read when it fires (see [Gating triggers](#gating-triggers))
- wrap all the callbacks of one change in a block (see [Wrapping the callbacks](#wrapping-the-callbacks))
- tell its callback whether the associated record was added, changed or removed, and where it came from or went to (see [Knowing what changed](#knowing-what-changed))

## How it works

1. `watches(...)` registers a **trigger**, and tells Watchtower to observe the records of the association it names (`association:`), or the class an `affects:` scope reads (`class:`).
2. When one of those records is added, changed or removed, an [`ActiveRecord::Observer`](https://github.com/rails/rails-observers) hook records the change (the associated record's class, id and changed attributes, and the foreign keys that tied it to its owners before it moved or was destroyed). By default Watchtower runs one callback for all of a record's changes once the transaction commits. A trigger can instead run one callback for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)).
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
| `callback:` | What to run on each owner in the audience. A `Symbol`/`String` is sent to the owner; a `Proc` is called (passed the owner if it takes an argument). It is also offered the change (see [Knowing what changed](#knowing-what-changed)). |
| `attribute:` / `attributes:` | Fire for a changed associated record only when one of these attributes changed. An added or removed record always fires. Omit to fire on any change. |
| `includes:` | Associations to eager-load on the audience before running the callback (avoids N+1 in the callback). |
| `enabled:` | A predicate gating the trigger (see [Gating triggers](#gating-triggers)). Defaults to always enabled. |
| `inline:` | Run the callback in the thread that made the change instead of in a job (see [Running inline](#running-inline)). Defaults to `false`. |
| `around:` | A block the callbacks of a change run inside (see [Wrapping the callbacks](#wrapping-the-callbacks)). |
| `at:` | When the trigger fires, `:commit` once the transaction commits or `:save` at each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). Defaults to `:commit`. |

### Audience: `association:` vs `affects:`

With `association:`, Watchtower finds owners by joining that association to the associated record.

```ruby
# Reindex the author of a review that is added, changed or removed (Author has_many :reviews, through: :books)
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

A trigger with no `attributes` fires on any change. A trigger always fires when an associated record is added or removed, regardless of the watched attributes (see [Moves and destroys](#moves-and-destroys)).

### Callbacks

```ruby
watches association: :books, callback: :reindex!                 # method on the owner
watches association: :books, callback: ->(author) { author.reindex! }  # proc, passed the owner
```

Several triggers of an observing class that share a callback and an `around:`, and run the same way (queued or inline, at the same `at:`), run it once per owner.

```ruby
watches association: :books, attribute: :title, callback: :reindex!
watches association: :books, attribute: :genre, callback: :reindex!

book.update!(title: "Persuasion", genre: "Novel")  # reindexes the book's author once, not twice
```

### Knowing what changed

The callback is offered the owner and the change, a `Watchtower::OwnerChange` describing how the change affected that owner. A proc receives both, and a method on the owner receives the change as its argument.

```ruby
class Author < ApplicationRecord
  has_many :books
  watches association: :books, callback: :book_changed   # or callback: ->(author, change) { ... }

  def book_changed(change)
    case change.kind
    when :added   then record_arrival(change.record, from: change.previous_owners)
    when :removed then record_departure(change.record_id, to: change.owners)
    when :changed then refresh_book(change.record, change.changed_attributes)
    end
  end
end
```

| Method | Value |
| --- | --- |
| `kind` | `:added` when the record was added to the owner's association<br>`:removed` when it was removed from it, including by being destroyed<br>`:changed` when it changed while staying in it<br>`nil` when its previous owners cannot be known |
| `record` | the associated record; `nil` when a job runs after it was destroyed or deleted |
| `record_class`, `record_id` | the associated record's class and id |
| `destroyed?` | whether the record was destroyed |
| `changed_attributes` | the attributes the change saved; empty for a destroy, unless a trigger that fires at the commit merged it with an earlier save |
| `previous_owners` | the owners before the change, as a relation, which for an added record says where it came from; `nil` when they cannot be known |
| `owners` | the owners after the change, as a relation, which for a removed record says where it went; none once it is destroyed |

A trigger that fires at the commit describes the transaction's changes merged into one, so a book moved from Ada to Grace to Hedy tells Ada it was removed, with Hedy as its owner, and tells Hedy it was added, with Ada as its previous owner. The callback does not run on Grace, who held the book only inside the transaction. A trigger that fires `at: :save` describes each step.

What an owner can be told depends on the kind of watch.

| Watch | Declaration | `kind` | `previous_owners` / `owners` |
| --- | --- | --- | --- |
| Direct `has_many` or `has_one` | `has_many :books`<br>`watches association: :books, callback: :book_changed` | `:added`, `:removed`, `:changed` | before: from the book's previous `author_id`; after: the book's current author |
| Polymorphic | `has_many :comments, as: :commentable`<br>`watches association: :comments, callback: :comment_changed` | `:added`, `:removed`, `:changed` | before: from the comment's previous `commentable_id` and `commentable_type`; after: the comment's current commentable |
| `has_many :through` | `has_many :reviews, through: :books`<br>`watches association: :reviews, callback: :review_changed` | `:added`, `:removed`, `:changed`¹ | before: from the previous foreign keys of the review or the book; after: the current owners |
| Nested `has_many :through` | `has_many :review_comments, through: :books`<br>`watches association: :review_comments, callback: :comment_changed` | `:changed`, or `nil` when the comment may have moved²; `:added` or `:removed` for a change to a book¹ | before: `nil` when the comment may have moved², the current owners for another change to the comment, and from the book's previous `author_id` for a change to a book; after: the current owners |
| Scoped association | `has_many :published_books, -> { where(published: true) }, class_name: "Book"`<br>`watches association: :published_books, callback: :book_changed` | `nil`⁵ | before: `nil`⁵; after: the current owners |
| `affects:` scope | `watches class: "Book", affects: ->(book) { Author.where(id: book.author_id) }, callback: :book_changed` | `:removed` on a destroy; `nil` otherwise³ | before: known only on a destroy³; after: the scope's result, or none after a destroy |
| The owner `belongs_to` the associated record | on `Book`: `belongs_to :author`<br>`watches association: :author, callback: :author_changed` | `:changed`; `:removed` when the author is destroyed⁴ | before: the books that point at the author; after: the same books, or none once the author is destroyed |

1. A change can come from the record the association passes through. When a `Book` moves from Ada to Grace, Ada loses the book's reviews and Grace gains them, and `change.record` is the `Book`, not a review.
2. When the association's source is itself a `has_many :through`, as here where `Book` has `has_many :review_comments, through: :reviews, source: :comments`, the associated record holds no foreign key that Watchtower reads to find its owners. Watchtower then treats a change to any of the record's own `belongs_to` foreign keys as a possible move, and leaves its previous owners unknown. Destroying such a record runs no callback, since neither its previous owners nor its current ones can be read (see [Caveats](#caveats)).
3. An `affects:` scope may select owners by anything, so Watchtower cannot tell which owners a change added or removed. A destroy's owners are read before the record is gone.
4. Saving an `Author` does not change which books point at it, so it neither adds nor removes any.
5. A scope can take in or leave out a record without any key changing, e.g. when a book is published, so Watchtower cannot tell which owners gained or lost it. This applies wherever a scope appears along the association, including on an association it passes through.

## Moves and destroys

An associated record removed from an owner leaves the owner behind that the association join no longer reaches. Watchtower runs the callback on that owner too.

- **Moves.** A save that changes the foreign key linking the associated record to its owners, and for a polymorphic association the type, runs the callback on the owner the record was removed from and the owner it was added to. Moving a `Book` to another `Author` reindexes both.
- **Destroys.** Destroying an associated record runs the callback on the owners it had.
- **Records an association passes through.** For `has_many :reviews, through: :books`, moving or destroying a `Book` changes an author's reviews without any `Review` saving, so a trigger on `:reviews` also watches `Book`. Only a change to the `Book`'s foreign keys fires it (its `author_id`, or for `has_many :publishers, through: :books`, its `publisher_id`), not every `Book` save. A trigger declared before its association (with `class:`) starts watching the record it passes through the next time the observer reinitializes after the association exists. The observer reinitializes once the application has initialized, and whenever a new trigger watches a class it does not yet observe.

For a queued trigger, the owners before the change are found from the foreign keys the change carries, not queried in the thread that made the change, so a save costs no more reads with a trigger than without one. The one exception is an `affects:` trigger on a destroyed record, whose scope is evaluated at the destroy, since the job can no longer load the record.

## Running inline

`inline: true` runs the callback in the thread that made the change rather than in a job, after the change commits by default, or inside the transaction with `at: :save` (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). Use it when the callback depends on context that thread holds, e.g. a batch being collected or a thread-local mode, or needs to write immediately.

```ruby
watches association: :books, callback: :reindex!, inline: true
```

## Wrapping the callbacks

`around:` wraps the loop that runs the callback. When a change fires the trigger, Watchtower finds every owner the change reaches and calls the callback on each. `around:` is a `Proc` called once for the change, with a block that runs that whole loop. A queued trigger runs it inside the change's `Watchtower::Job`, and an inline one in the thread that made the change, when the trigger fires. It is never called per owner.

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

A block inside the callback would instead open and send a batch for every owner. Triggers that share an observing class, a callback and an `around:` run the callback once per owner inside that one block. Triggers whose `around:` differs run inside their own.

## Choosing when a trigger fires

`at:` sets when a trigger fires, and with it when its `enabled:` is read.

- **`at: :commit` converges** on the committed state. The trigger fires once the transaction commits, once for each associated record the transaction added, changed or removed, on the owners the record had before the transaction and the owners it has after. Anything in between is skipped, and a change that rolls back fires nothing.
- **`at: :save` follows every step.** The trigger fires as each save or destroy happens, inside the transaction, on the owners the record had before that save and the owners it has when the callback runs.

An associated record can have several owners, e.g. a publisher belongs to every author who has a book it published (`has_many :publishers, through: :books`), so a change to a publisher reaches all of them.

`inline:` sets where the callback runs. The two combine freely.

| | `at: :commit` (default) | `at: :save` |
| --- | --- | --- |
| queued | One job per associated record added, changed or removed, enqueued once the transaction commits. A rollback enqueues nothing. | One job per save, enqueued inside the transaction. A job backend that stores jobs in the same database (Delayed Job) commits or rolls back the job with the change. |
| `inline: true` | The callback runs once the transaction commits, once per associated record added, changed or removed. | The callback runs inside the transaction, once per save, so what it writes commits or rolls back with the change. |

**Queued, `at: :commit` (the default).** Best for updating something outside the database, e.g. a search index, a cache or another system's copy of the data. The job sees only committed data, never runs for a change that rolls back, and runs once for a record saved several times in one transaction.

```ruby
# Reindex an author's search document when one of their books changes.
watches association: :books, callback: :reindex!
```

**Inline, `at: :commit`.** Best for work that the code making the changes collects and finishes itself. A script that rewrites many books opens a batch, the callbacks add each affected author to it, and the script reindexes each author once when it finishes. The callback runs in the script's thread, where it can reach the batch, and only for changes that committed.

```ruby
watches association: :books, callback: :add_to_reindex_batch, inline: true, enabled: -> { ReindexBatch.open? }
```

**Inline, `at: :save`.** Best for a value on the owner that later steps of the same transaction rely on. Suppose `authors.latest_published_on` holds the date of each author's latest book, and one transaction adds a book and then selects authors by that date. A callback that fires at the commit would update the column after that query had run. One that fires at the save updates it as the book is saved, so the query sees the new date, and a rollback undoes the update along with the book.

```ruby
watches association: :books, attribute: :published_on, callback: :update_latest_published_on!, inline: true, at: :save
```

**Queued, `at: :save`.** Best for work that must not be lost, when the queue stores its jobs in the application's database. Delayed Job and GoodJob do, so a job enqueued inside the transaction commits or rolls back with the change, and a process that dies just after the commit cannot lose it. That suits keeping another system's copy of each author's book list current, where a lost job leaves it stale until the author's books change again. With a queue outside the database, e.g. Sidekiq, the job is enqueued even when the transaction rolls back and can run before the change commits, so keep the default.

```ruby
watches association: :books, callback: :notify_storefront!, at: :save
```

A queued `at: :save` trigger depends on Active Job writing the job when `perform_later` is called. Active Job's `enqueue_after_transaction_commit` setting instead holds every enqueue until the surrounding transaction commits, so the trigger's jobs would no longer commit or roll back with the change. Declaring a queued `at: :save` trigger therefore raises `ArgumentError` while Active Job would defer `Watchtower::Job`'s enqueue. Watchtower never changes the setting itself, so turn it off for `Watchtower::Job`, or keep the trigger at the commit. The check runs when the trigger is declared, so it misses a setting turned on after the trigger was declared.

```ruby
# config/initializers/watchtower.rb
Rails.application.config.to_prepare do
  # On Rails 7.2, only :never stops the queue adapter from deferring, and `load_defaults 7.2` leaves it to the adapter.
  Watchtower::Job.enqueue_after_transaction_commit = Rails.gem_version < Gem::Version.new("8.0") ? :never : false
end
```

### What fires, and how often

A trigger that fires at the commit fires once for each associated record the transaction added, changed or removed, on all of its saves and destroys merged into one, even when they went through several instances of the record. It fires from a transaction callback (`current_transaction.after_commit`) once the outermost transaction commits, leaving out every save that rolled back, including one inside a savepoint (`requires_new: true`) that rolled back. A trigger that fires at the save fires once per save. Either way, each time a trigger fires, its callback runs once for each owner the change reaches, however many of the callback's triggers the change matches among those that run the same way (see [Callbacks](#callbacks)). A change reaches the owners the record had before it and the owners the record has when the callback runs, which are read from the database.

| In one transaction | `at: :commit` | `at: :save` |
| --- | --- | --- |
| A book's `title` is saved twice | `reindex!` runs once on its author, after the commit | `reindex!` runs twice on its author, once for each save |
| A book moves from Ada to Grace, then to Hedy | the callback runs on Ada and Hedy. Grace held the book only inside the transaction, so nothing she derives changed | inline, the callback runs on Ada and Grace at the first save, and on Grace and Hedy at the second. Queued, each save's job runs on the owner before that save and on the owner when the job runs. With a queue in the application's database that is after the commit, so Ada and Hedy, then Grace and Hedy. A queue outside the database can run a job before the commit, when its connection still sees an earlier owner |
| The transaction rolls back | nothing runs | inline callbacks have already run, and only their database writes are undone; queued jobs are rolled back only by a queue in the same database |

## Gating triggers

`enabled:` switches a specific trigger off for the dynamic extent of a block, e.g. around a bulk operation that would otherwise fire the callback for every row it touches, when a single batch recompute or a periodic full rebuild is cheaper.

```ruby
class Author < ApplicationRecord
  watches association: :books, callback: :reindex!, enabled: -> { Reindexing.enabled? }
end

# Rewrite thousands of books without a reindex per book, then reindex every author once:
Reindexing.without { Book.find_each { |book| book.update!(title: book.title.strip) } }
Author.find_each(&:reindex!)
```

A queued trigger's callback runs in a job, after a thread-local set inside the block is gone. Watchtower therefore evaluates `enabled:` **when the trigger fires, in the thread that made the change**, i.e. as the change commits, or for an `at: :save` trigger as the record saves, and carries a queued trigger's decision into the job.

- The observer evaluates each matching trigger's `enabled:` predicate as it fires. It runs the inline triggers that pass, and enqueues the queued triggers that pass, recording the other queued triggers' keys in the job payload as suppressed. If no matching queued trigger passes, no job is enqueued at all.
- The job honors that recorded decision; it does not re-evaluate the predicate.

So a trigger gated off inside a block stays off for changes that fire in that block, while other triggers on the same record (e.g. a different model's `watches` on the same class) are unaffected. A block opened inside a transaction does not cover the transaction's commit, so a change saved in the block and committed after it is gated by the context at the commit, unless its trigger fires `at: :save`. Triggers without `enabled:` are always enabled.

A predicate may be a no-arg `Proc` (a context check, as above), a one-arg `Proc` (passed the associated record, for per-record gating), or a `Symbol`/`String` sent to the associated record (e.g. `enabled: :indexable?`).

## Asynchronous processing

Queued callbacks run in `Watchtower::Job`, an `ActiveJob`, so the change that fired them is not slowed by the work. It uses the application's default queue adapter (the `:async` adapter in development, so a save does not need a running Delayed Job worker). Configure the queue and adapter as you would any other job. An inline trigger runs its callback in the thread that made the change instead (see [Running inline](#running-inline)).

## Caveats

- **Nested through associations.** When an association's source is itself a `has_many :through`, Watchtower watches the association's own records and the records on its `through:` side, but not the records inside the source. With `has_many :review_comments, through: :books` on `Author`, where `Book` has `has_many :review_comments, through: :reviews, source: :comments`, it watches the comments and the books, not the reviews. https://github.com/combinaut/watchtower/issues/15 tracks the gaps.

  | Change | Reaches |
  | --- | --- |
  | A comment is changed | its author |
  | A book moves to another author | both authors |
  | A book is destroyed | its author |
  | A comment moves to a review on another book | only the new author |
  | A comment is destroyed | no author |
  | A review moves to another book, or is destroyed | no author |
- **`affects:` on a move.** An `affects:` scope is evaluated on the associated record as it is when the callback runs, so it reaches only the current owners.
- **STI.** The change payload identifies the associated record by `base_class`, so triggers are matched against the base class of an STI hierarchy.
- **Scoped associations.** An associated record that stops matching an association's scope without a key changing, e.g. a book unpublished under `has_many :published_books, -> { where(published: true) }`, is no longer joined to its owner, so the change reaches no owner and no callback runs.
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
