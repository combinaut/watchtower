# Watchtower

Run a callback on a record whenever one of its associated records is added, changed or removed.

Models often keep state derived from their associations. That state goes out of date when an associated record is **added** to the association (created in it or moved into it), **changed** while it stays in it, or **removed** from it (moved to another record or destroyed). Watchtower lets the model declare that dependency once with `watches`, and runs the callback that brings each affected record, a **watcher**, up to date whenever one of those changes happens.

```ruby
class Author < ApplicationRecord
  has_many :books

  # Reindex an author when one of their books is added, changed or removed.
  watches association: :books, callback: :reindex!
end
```

If you are looking to react to a record's own changes, its own callbacks will serve you better. Watchtower is for the records on the other side of an association, the ones whose model declares `watches`.

A trigger can also:

- be switched off for the changes made inside a block (see [Gating triggers](#gating-triggers))
- run once when the transaction commits, for all of its changes combined, or once for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires))
- run its callback in a background job, or inline in the thread that made the change (see [Running inline](#running-inline))
- wrap all the callbacks a trigger runs when it fires in a block (see [Wrapping the callbacks](#wrapping-the-callbacks))
- tell its callback whether the associated record was added, changed or removed, and where it came from or went to (see [Knowing what changed](#knowing-what-changed))

## How it works

1. `watches(...)` registers a **trigger**, and tells Watchtower to observe the records of the association it names (`association:`), or the class an `affects:` scope reads (`class:`).
2. When one of those records is added, changed or removed, an [`ActiveRecord::Observer`](https://github.com/rails/rails-observers) hook records the change (the associated record's class, id and changed attributes, and the foreign keys that tied it to its watchers before it moved or was destroyed). By default Watchtower combines a transaction's changes to a record and runs the callback once the transaction commits. A trigger can instead run one callback for each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). A write that skips callbacks, e.g. `update_all`, fires triggers only when reported with `Watchtower.report_changes` (see [Changes made without callbacks](#changes-made-without-callbacks)).
3. Watchtower finds the **watchers** the change reaches, the records whose model declared the trigger, and runs the callback on each.

## Installation

```ruby
gem "watchtower", git: "git@github.com:combinaut/watchtower.git"
```

The engine adds `watches` to every model and registers the observer, so no initializer is needed. Watchtower requires Rails 7.2 or newer.

## The example used in this guide

An author's search document lists their books, so `Author` reindexes when one of its books is added, changed or removed.

```ruby
class Author < ApplicationRecord
  has_many :books

  watches association: :books, callback: :reindex!
end
```

The sections below show how each option changes what happens when an editor fixes a book's author. The book is first moved to the wrong author, then to the right one, and retitled, all in one transaction.

```ruby
Book.transaction do
  persuasion.update!(author: grace)    # moved from Ada to Grace by mistake
  persuasion.update!(author: hedy)     # then to Hedy
  persuasion.update!(title: "Persuasion: A Novel")
end
```

## Usage

`watches` is available on every model. It accepts the following options:

| Option | Description |
| --- | --- |
| `association:` | A `has_many` / `belongs_to` on the observing model. When one of its records is added, changed or removed, Watchtower runs the callback on the watchers the change reaches. |
| `affects:` | An alternative to `association:`, a `Proc` (given the associated record) or method name returning the relation of watchers to run on. Use it when the watchers can't be reached by a single association join. Requires `class:`. |
| `class:` | The observed class. Inferred from `association:`. Give it when using `affects:`, or when the association isn't defined yet at declaration time. |
| `callback:` | What to run on each watcher a change reaches. A `Symbol`/`String` is sent to the watcher; a `Proc` is called (passed the watcher if it takes an argument). It is also offered the change (see [Knowing what changed](#knowing-what-changed)). |
| `attribute:` / `attributes:` | Fire for a changed associated record only when one of these attributes changed. An added or removed record always fires. Omit to fire on any change. |
| `includes:` | Associations to eager-load on the watchers before running the callback (avoids N+1 in the callback). |
| `enabled:` | Whether Watchtower runs the callback for a change, read as the change is made (see [Gating triggers](#gating-triggers)). Defaults to always running it. |
| `at:` | When the trigger fires, `:commit` once the transaction commits or `:save` at each save (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)). Defaults to `:commit`. |
| `inline:` | Run the callback in the thread that made the change instead of in a job (see [Running inline](#running-inline)). Defaults to `false`. |
| `around:` | A `Proc` that wraps all the callbacks a trigger runs when it fires, e.g. in a transaction (see [Wrapping the callbacks](#wrapping-the-callbacks)). |

### Finding the watchers: `association:` vs `affects:`

The watchers are the records whose model declares `watches`, in the example the authors. Watchtower runs the callback on the watchers a change reaches. With `association:`, Watchtower finds them by joining that association to the changed record, so any association works, including one through another.

```ruby
class Author < ApplicationRecord
  has_many :books
  has_many :reviews, through: :books

  watches association: :reviews, callback: :reindex!
end
```

A new review of Persuasion reindexes Hedy, whose book it reviews. In the example, moving Persuasion also moves its reviews, so the editor's transaction reindexes Ada and Hedy through this trigger too, though no review was saved (see [Moves and destroys](#moves-and-destroys)).

When the watchers are not reachable by an association, return them yourself with `affects:`. Suppose each book stores its co-authors' ids in a column rather than an association.

```ruby
watches class: "Book",
        affects: ->(book) { Author.where(id: book.co_author_ids) },
        callback: :reindex!
```

`affects:` is given the changed record and returns its watchers as a relation. `class:` names the class to observe, since there is no association to infer it from. Watchtower evaluates `affects:` when the callback runs, so after a book loses a co-author the callback runs only on the current co-authors (see [Caveats](#caveats)).

### Filtering by attribute

`attribute:` (or `attributes:`) limits a trigger to changes that save one of the named attributes. An associated record added to the association or removed from it always fires the trigger, whatever changed.

```ruby
watches association: :books, attribute: :title, callback: :reindex!
```

In the example, the editor's transaction still reindexes Ada and Hedy, because Persuasion was removed from Ada and added to Hedy. A later save that changes only the book's price does not reindex Hedy:

```ruby
persuasion.update!(price: 12)    # no reindex: price is not a watched attribute
```

A trigger with no `attribute:` fires on any change.

### Callbacks

`callback:` is what Watchtower runs on each watcher a change reaches. Watchtower calls a method name on the watcher, and passes the watcher to a `Proc`.

```ruby
watches association: :books, callback: :reindex!                         # calls author.reindex!
watches association: :books, callback: ->(author) { author.reindex! }   # passes the author
```

The callback can also be given the change, i.e. whether the book was added, changed or removed and where it came from (see [Knowing what changed](#knowing-what-changed)).

Several triggers of a model that share a callback and an `around:`, and run the same way (queued or inline, at the same `at:`), run the callback once per watcher:

```ruby
watches association: :books, attribute: :title, callback: :reindex!
watches association: :books, attribute: :genre, callback: :reindex!

persuasion.update!(title: "Persuasion: A Novel", genre: "Romance")    # reindexes Hedy once, not twice
```

`includes:` preloads associations on the watchers before the callbacks run, so a callback that reads one costs one query for all the watchers rather than one each. In the publisher rename (see [Wrapping the callbacks](#wrapping-the-callbacks)), each author's `refresh_publisher_names` reads the author's publishers:

```ruby
watches association: :publishers, callback: :refresh_publisher_names, includes: :publishers
```

## Gating triggers

`enabled:` controls whether Watchtower runs the callback for a change. Watchtower reads its value as each change is made, and skips the callback for changes made while the value is false.

The usual use is switching a trigger off around a bulk operation that would otherwise run the callback for every row, when your application rebuilds the result once afterwards instead. In the example, a script that tidies every book title would otherwise reindex each author once per book.

```ruby
class Author < ApplicationRecord
  has_many :books

  watches association: :books, callback: :reindex!, enabled: -> { Reindexing.enabled? }
end

# Reindexing is your application's code, not Watchtower's: a thread-local switch.
Reindexing.without do
  Book.find_each { |book| book.update!(title: book.title.strip) }
end
Author.reindex_all     # your application rebuilds the index once
```

Inside the block the value is false, so Watchtower runs no callback and enqueues no job for any of the books. Outside it, the editor's transaction in the example runs as before. To reindex only the authors the operation affected, once each, collect them instead (see [Collecting changes across transactions](#collecting-changes-across-transactions)).

Watchtower keeps the decision it reads at each change until the trigger fires:

- A change made inside the block stays gated off even when its transaction commits after the block ends, e.g. when the block runs inside a transaction your application opened around it.
- A transaction that changes one book both inside and outside the block fires the trigger once, because one of its changes was made while the value was true.
- A queued trigger's decision travels with its job, so the job never reads the value again, in a thread where the switch no longer exists.

The value gates only its own trigger. Another trigger on the same book, e.g. another model's `watches`, still fires.

`enabled:` may be:

- a `Proc` with no arguments, for a check of context, as above
- a `Proc` with one argument, which Watchtower passes the associated record, e.g. `enabled: ->(book) { book.published? }`
- a `Symbol` or `String`, which Watchtower sends to the associated record, e.g. `enabled: :published?`

A trigger with no `enabled:` always fires.

## Choosing when a trigger fires

`at:` sets when a trigger fires.

### `at: :commit` (the default)

The trigger fires once the transaction commits. Watchtower combines all of the transaction's saves of one associated record into a single change, which reaches the records that watched it before the transaction and those that watch it after. Anything in between is skipped. The callback then runs once on each watcher the transaction's changes reach, however many of its associated records changed, e.g. a transaction that retitles two of Ada's books reindexes her once.

```ruby
watches association: :books, callback: :reindex!
```

In the example, Persuasion was Ada's before the transaction and is Hedy's after it, so the transaction runs:

```ruby
ada.reindex!     # once the transaction commits
hedy.reindex!
```

Grace held the book only inside the transaction, so she is not reindexed, and the retitle is folded into Hedy's reindex. Had the transaction rolled back, nothing would run.

This suits anything that should reflect only what was committed, e.g. a search index, a cache or another system's copy of the data.

### `at: :save`

The trigger fires as each save or destroy happens, inside the transaction. An inline trigger runs its callback right then, on the records that watched the associated record before that save and those that watch it after.

```ruby
watches association: :books, callback: :record_book_history, inline: true, at: :save
```

In the example, each of the three saves runs the callback:

```ruby
ada.record_book_history     # save 1: Persuasion left Ada
grace.record_book_history   # save 1: and joined Grace
grace.record_book_history   # save 2: left Grace
hedy.record_book_history    # save 2: and joined Hedy
hedy.record_book_history    # save 3: retitled
```

This suits work that has to see every step rather than the outcome, e.g. a history that shows the book passed through Grace. The callback writes inside the transaction, so a rollback undoes its writes along with the book.

A queued trigger that fires at the save enqueues a job at each save instead, and each job runs later, reading the book as it is when the job runs. It cannot see the steps, so it does not suit a history (see [Queued, `at: :save`](#queued-at-save)).

### What fires, and how often

A trigger that fires at the commit fires once for the transaction, on every associated record it added, changed or removed, each record's saves and destroys combined into one, even when they went through several instances of the record. It fires from a transaction callback (`current_transaction.after_commit`) once the outermost transaction commits, leaving out every save that rolled back, including one inside a savepoint (`requires_new: true`) that rolled back. A trigger that fires at the save fires once per save. Either way, each time a trigger fires, its callback runs once for each watcher the changes reach, however many of the changes reach it and however many of the callback's triggers they match among those that run the same way (see [Callbacks](#callbacks)). A callback that takes the change runs once for each change instead (see [Knowing what changed](#knowing-what-changed)). A change reaches the records that watched the associated record before it and those that watch it when the trigger fires, which are read from the database before any of its callbacks run (see [Callbacks that make changes](#callbacks-that-make-changes)).

| In one transaction | `at: :commit` | `at: :save` |
| --- | --- | --- |
| A book's `title` is saved twice | `reindex!` runs once on its author, after the commit | `reindex!` runs twice on its author, once for each save |
| Two of Ada's books are retitled | `reindex!` runs once on Ada, after the commit | `reindex!` runs twice on Ada, once for each save |
| A book moves from Ada to Grace, then to Hedy | the callback runs on Ada and Hedy. Grace held the book only inside the transaction, so nothing she derives changed | inline, the callback runs on Ada and Grace at the first save, and on Grace and Hedy at the second. Queued, each save's job runs on the book's watcher before that save and on its watcher when the job runs. With a queue in the application's database that is after the commit, so Ada and Hedy, then Grace and Hedy. A queue outside the database can run a job before the commit, when its connection still sees an earlier watcher |
| The transaction rolls back | nothing runs | inline callbacks have already run, and only their database writes are undone; queued jobs are rolled back only by a queue in the same database |

## Running inline

By default the callback runs in a `Watchtower::Job` (see [Asynchronous processing](#asynchronous-processing)). `inline: true` runs it in the thread that made the change instead, when the trigger fires. That is once the transaction commits by default, or inside the transaction with `at: :save` (see [Choosing when a trigger fires](#choosing-when-a-trigger-fires)).

### Queued (the default)

```ruby
watches association: :books, callback: :reindex!
```

In the example, the commit enqueues one job for the transaction, and the job runs:

```ruby
ada.reindex!     # in a job, after the commit
hedy.reindex!
```

The editor's request returns without waiting for the reindex. This suits work that can finish a moment later, which is most work.

### `inline: true`

```ruby
watches association: :books, callback: :expire_cached_page, inline: true
```

In the example, the commit runs the callbacks before the editor's request continues:

```ruby
ada.expire_cached_page     # in the editor's thread, as the transaction commits
hedy.expire_cached_page
```

The request then redirects to Hedy's page, which already shows Persuasion. A job could run after the redirect and show the old page.

Use it when the callback has to finish before the code that made the change goes on, or needs something only that thread holds, e.g. the current user, or a batch the code is collecting.

#### Collecting changes across transactions

Watchtower runs the callback once per watcher for each transaction (see [`at: :commit`](#at-commit-the-default)), but not across transactions. A nightly import that saves each book in its own transaction, so that one bad row rolls back only itself, would reindex Ada once for each of her 40 books. To reindex each author once per import, your application collects the authors in a batch of its own and reindexes them when the import ends. Watchtower's part is to run the callback that adds each author to the batch. If your application rebuilds everything afterwards anyway, switch the trigger off instead (see [Gating triggers](#gating-triggers)).

```ruby
class Author < ApplicationRecord
  has_many :books

  watches association: :books, callback: :add_to_reindex_batch, inline: true
end

# ReindexBatch is your application's code, not Watchtower's.
ReindexBatch.open do                  # reindexes each collected author once when the block ends
  feed.each_row { |row| Book.transaction { import_book(row) } }
end
```

Watchtower runs the callback in the import's thread, where it can reach the open batch, and only for books whose transaction committed, so a row that fails never adds its author.¹

1. Outside a batch, e.g. when an editor saves a single book, `add_to_reindex_batch` would need to reindex the author immediately instead. The same applies to a book saved inside the block whose transaction commits after it ends. Watchtower runs the callback in both cases, so your application decides what it does.

### `inline: true, at: :save`

```ruby
watches association: :books, attribute: :published_on, callback: :update_latest_published_on, inline: true, at: :save
```

The callback runs inside the transaction as each book is saved, so the transaction's later statements read what it wrote, and a rollback undoes it along with the book. Suppose the editor's transaction also sets Persuasion's `published_on`, then lists the authors who published this month. The list already includes Hedy, because her `latest_published_on` changed as the book was saved, not after the commit.

### Queued, `at: :save`

```ruby
watches association: :books, callback: :notify_storefront, at: :save
```

The example enqueues one job per save, three in all, inside the transaction. With a queue that stores jobs in the application's database, e.g. Delayed Job or GoodJob, each job commits or rolls back with the change, so a process that dies just after the commit cannot lose it. With a queue outside the database, e.g. Sidekiq, a job is enqueued even when the transaction rolls back, and can run before the change commits, so keep the default.

A queued `at: :save` trigger depends on Active Job writing the job when `perform_later` is called. Active Job's `enqueue_after_transaction_commit` setting instead holds every enqueue until the surrounding transaction commits, so the trigger's jobs would no longer commit or roll back with the change. Declaring a queued `at: :save` trigger therefore raises `ArgumentError` while Active Job would defer `Watchtower::Job`'s enqueue. Watchtower never changes the setting itself, so turn it off for `Watchtower::Job`, or keep the trigger at the commit. The check runs when the trigger is declared, so it misses a setting turned on after the trigger was declared.

```ruby
# config/initializers/watchtower.rb
Rails.application.config.to_prepare do
  # On Rails 7.2, only :never stops the queue adapter from deferring, and `load_defaults 7.2` leaves it to the adapter.
  Watchtower::Job.enqueue_after_transaction_commit = Rails.gem_version < Gem::Version.new("8.0") ? :never : false
end
```

## Wrapping the callbacks

`around:` wraps all the callbacks a trigger runs when it fires, once for a transaction's commit, or once for each save with `at: :save`. It is a `Proc` that takes a block. When the trigger fires, Watchtower calls the `Proc` once and passes it a block that runs the callback on every watcher the changes reach. Your `Proc` calls that block, and decides what happens before and after it. It is not given the watchers.

A queued trigger runs its callbacks inside a `Watchtower::Job`, which your application's code never calls, so `around:` is the way to wrap them. An inline trigger runs its callbacks in the thread that made the change, and `around:` wraps them there too, so every place that saves a record gets the same wrapping without having to remember it.

The wrapping pays off when one change reaches many watchers. A publisher belongs to every author who has a book it published, so renaming one updates all of them. Here each author stores the names of their publishers, and `around:` runs all the updates in one transaction, so the authors are written together and either all change or none does.

```ruby
class Author < ApplicationRecord
  has_many :books
  has_many :publishers, through: :books

  watches association: :publishers,
          callback: :refresh_publisher_names,
          around: ->(&run_callbacks) { Author.transaction { run_callbacks.call } }
end
```

Renaming Penguin, whose books 300 authors wrote, runs one job. In it, Watchtower calls your `Proc`, and the block it passes runs `refresh_publisher_names` on each author:

```ruby
Author.transaction do                                   # your around: Proc
  penguin_authors.each(&:refresh_publisher_names)       # the block Watchtower passes: its loop over the 300 authors
end                                                     # the 300 updates commit together
```

`around:` covers the callbacks of one commit only, or of one save with `at: :save`. Each transaction gets a block of its own, so to collect the work of many transactions, collect it in your application instead (see [Collecting changes across transactions](#collecting-changes-across-transactions)).

Triggers of a model that share a callback and an `around:` run the callback once per watcher inside one block. Triggers whose `around:` differs run inside their own.

## Knowing what changed

The callback is offered the watcher and the change, a `Watchtower::WatcherChange` describing how the change affected that watcher. A proc receives both, and a method on the watcher receives the change as its argument. A callback that takes the change runs once for each change that reaches the watcher, so a transaction that retitles two of Ada's books runs it on Ada twice, once with each change.

```ruby
class Author < ApplicationRecord
  has_many :books
  watches association: :books, callback: :book_changed   # or callback: ->(author, change) { ... }

  def book_changed(change)
    case change.kind
    when :added   then record_arrival(change.record, from: change.previous_watchers)
    when :removed then record_departure(change.record_id, to: change.watchers)
    when :changed then refresh_book(change.record, change.changed_attributes)
    end
  end
end
```

| Method | Value |
| --- | --- |
| `kind` | `:added` when the record was added to the watcher's association<br>`:removed` when it was removed from it, including by being destroyed<br>`:changed` when it changed while staying in it<br>`nil` when its previous watchers cannot be known |
| `record` | the associated record; `nil` when a job runs after it was destroyed or deleted |
| `record_class`, `record_id` | the associated record's class and id |
| `destroyed?` | whether the record was destroyed |
| `changed_attributes` | the attributes the change saved; empty for a destroy, unless a trigger that fires at the commit combined it with an earlier save |
| `previous_watchers` | the watchers before the change, as a relation, which for an added record says where it came from; `nil` when they cannot be known |
| `watchers` | the watchers after the change, as a relation, which for a removed record says where it went; none once it is destroyed |

A trigger that fires at the commit describes the transaction's changes to the record combined into one. In the example (see [The example used in this guide](#the-example-used-in-this-guide)), Ada is told Persuasion was removed, with Hedy as its watcher, and Hedy is told it was added, with Ada as its previous watcher. The callback does not run on Grace, who held the book only inside the transaction. A trigger that fires `at: :save` describes each step.

What a watcher can be told depends on the kind of watch.

| Watch | Declaration | `kind` | `previous_watchers` / `watchers` |
| --- | --- | --- | --- |
| Direct `has_many` or `has_one` | `has_many :books`<br>`watches association: :books, callback: :book_changed` | `:added`, `:removed`, `:changed` | before: from the book's previous `author_id`; after: the book's current author |
| Polymorphic | `has_many :comments, as: :commentable`<br>`watches association: :comments, callback: :comment_changed` | `:added`, `:removed`, `:changed` | before: from the comment's previous `commentable_id` and `commentable_type`; after: the comment's current commentable |
| `has_many :through` | `has_many :reviews, through: :books`<br>`watches association: :reviews, callback: :review_changed` | `:added`, `:removed`, `:changed`¹ | before: from the previous foreign keys of the review or the book; after: the current watchers |
| Nested `has_many :through` | `has_many :review_comments, through: :books`<br>`watches association: :review_comments, callback: :comment_changed` | `:changed`, or `nil` when the comment may have moved²; `:added` or `:removed` for a change to a book¹ | before: `nil` when the comment may have moved², the current watchers for another change to the comment, and from the book's previous `author_id` for a change to a book; after: the current watchers |
| Scoped association | `has_many :published_books, -> { where(published: true) }, class_name: "Book"`<br>`watches association: :published_books, callback: :book_changed` | `nil`⁵ | before: `nil`⁵; after: the current watchers |
| `affects:` scope | `watches class: "Book", affects: ->(book) { Author.where(id: book.author_id) }, callback: :book_changed` | `:removed` on a destroy; `nil` otherwise³ | before: known only on a destroy³; after: the scope's result, or none after a destroy |
| The watcher `belongs_to` the associated record | on `Book`: `belongs_to :author`<br>`watches association: :author, callback: :author_changed` | `:changed`; `:removed` when the author is destroyed⁴ | before: the books that point at the author; after: the same books, or none once the author is destroyed |

1. A change can come from the record the association passes through. When a `Book` moves from Ada to Grace, Ada loses the book's reviews and Grace gains them, and `change.record` is the `Book`, not a review.
2. When the association's source is itself a `has_many :through`, as here where `Book` has `has_many :review_comments, through: :reviews, source: :comments`, the associated record holds no foreign key that Watchtower reads to find its watchers. Watchtower then treats a change to any of the record's own `belongs_to` foreign keys as a possible move, and leaves its previous watchers unknown. Destroying such a record runs no callback, since neither its previous watchers nor its current ones can be read (see [Caveats](#caveats)).
3. An `affects:` scope may select watchers by anything, so Watchtower cannot tell which watchers gained or lost the record. A destroy's watchers are read before the record is gone.
4. Saving an `Author` does not change which books point at it, so it neither adds nor removes any.
5. A scope can take in or leave out a record without any key changing, e.g. when a book is published, so Watchtower cannot tell which watchers gained or lost it. This applies wherever a scope appears along the association, including on an association it passes through.

## Moves and destroys

When an associated record is removed from a watcher, the association join no longer reaches that watcher. Watchtower runs the callback on it too.

- **Moves.** A save that changes the foreign key linking the associated record to its watchers, and for a polymorphic association the type, runs the callback on the watcher the record was removed from and the watcher it was added to. Moving a `Book` to another `Author` reindexes both.
- **Destroys.** Destroying an associated record runs the callback on the records that watched it.
- **Records an association passes through.** For `has_many :reviews, through: :books`, moving or destroying a `Book` changes an author's reviews without any `Review` saving, so a trigger on `:reviews` also watches `Book`. Only a change to the `Book`'s foreign keys fires it (its `author_id`, or for `has_many :publishers, through: :books`, its `publisher_id`), not every `Book` save. A trigger declared before its association (with `class:`) starts watching the record it passes through the next time the observer reinitializes after the association exists. The observer reinitializes once the application has initialized, and whenever a new trigger watches a class it does not yet observe.

For a queued trigger, the watchers before the change are found from the foreign keys the change carries, not queried in the thread that made the change, so a save costs no more reads with a trigger than without one. The one exception is an `affects:` trigger on a destroyed record, whose scope is evaluated at the destroy, since the job can no longer load the record.

## Changes made without callbacks

Watchtower sees a change through the record's `after_save` and `after_destroy` callbacks, so a write that skips them, e.g. `update_all`, `update_columns` or `insert_all`, fires no trigger. `Watchtower.report_changes` tells Watchtower about such a write, and the triggers watching the records then fire as they would for a save of the named attributes.

```ruby
# Tidy every title in one statement, then let each author's triggers fire.
books = Book.where("title LIKE ' %'").to_a
Book.where(id: books.map(&:id)).update_all("title = TRIM(title)")
Watchtower.report_changes(books, attributes: [ :title ])
```

Watchtower reloads the records after the write, one query for each model, so `enabled:`, an `affects:` scope and the callback read the written values. It treats every record passed as changed in the named attributes, so pass only the records the write changed. Each reported change is handled like a save. Watchtower reads `enabled:` as the change is reported, holds the change for the commit, combines it with the transaction's other changes to the same book, and drops it if its transaction or savepoint rolls back. In the example, Ada is reindexed once, even if more than one of her books were tidied. Called outside a transaction, `report_changes` opens one, so all of the records fire together.

A reported change cannot move a record between watchers, since Watchtower cannot read the keys it had before the write. `report_changes` raises `ArgumentError`, reporting nothing, for an attribute that ties a record to its watchers, e.g. `author_id`. Save such a record through its callbacks instead.

## Complex use cases

### Callbacks that make changes

When a trigger fires, Watchtower finds every watcher and builds every `WatcherChange` before any of its callbacks run, so the callbacks see the changes as they stood when the trigger fired. A record a callback writes is a change of its own. It is not added to the changes the trigger is running on, and its commit-time triggers run after the callbacks of the trigger that made it, so the watchers hear of the changes in the order they were made.

Here the callback takes the change, and Ada's callback for Persuasion's change moves Emma to Grace:

```ruby
Book.transaction do
  persuasion.update!(title: "Persuasion: A Novel")
  emma.update!(title: "Emma: A Novel")
end
```

- **Moved through its callbacks**, e.g. `emma.update!(author: grace)`, the move is a change of its own, so Ada is told Emma was `:removed` and Grace that it was `:added`. Emma's retitle is still described as it stood when the trigger fired, so Ada is also told Emma `:changed`, before she is told of the move.
- **Moved without callbacks**, e.g. with `update_all`, Grace is never told, as with any write Watchtower does not see. `report_changes` cannot report a move (see [Changes made without callbacks](#changes-made-without-callbacks)), so move a record through its callbacks.

When the change a callback makes fires depends on how its trigger runs:

| The trigger that saves the record | Its save fires the triggers watching it | So they run |
| --- | --- | --- |
| `inline: true, at: :save` | during the save | inside the callback that made it, before the save returns |
| `inline: true` | when the save's own transaction commits, or an `around:` transaction around it, as in [Wrapping the callbacks](#wrapping-the-callbacks) | after every callback of the trigger that made it, and after the changes made before it, before the save or commit that started the chain returns |
| Queued, either `at:` | in a job of its own, enqueued when the save's transaction commits | after the job that made it |

So when a callback's save returns, the inline commit-time triggers it fires have not run yet.

An `at: :save` trigger runs inside the save that fires it, so its callbacks can run in the middle of another trigger's. When one save fires several callbacks and one of them moves the record through its callbacks, a callback that runs later on that save is told of the move first, and then of the save as it stood before the move.

A callback whose writes fire the trigger that ran it, directly or through other triggers, loops. Inline at `at: :save`, the loop recurses until it ends in a `SystemStackError`. Inline at `at: :commit`, each round runs after the last, and the change that started it never returns. Queued, each job enqueues the next, and nothing stops it. Watchtower does not detect loops, so check that a callback's writes cannot lead back to it.

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
- **`affects:` on a move.** An `affects:` scope is evaluated on the associated record as it is when the callback runs, so it reaches only the current watchers.
- **STI.** The change payload identifies the associated record by `base_class`, so triggers are matched against the base class of an STI hierarchy.
- **Scoped associations.** An associated record that stops matching an association's scope without a key changing, e.g. a book unpublished under `has_many :published_books, -> { where(published: true) }`, is no longer joined to its watcher, so the change reaches no watcher and no callback runs.
- **Saves through an out-of-date instance.** A move's previous watcher is the one the saving instance last loaded or saved, not the one stored in the database, so a save costs no extra read. When a book is loaded under Ada, another process moves it to Grace and commits, and the first instance then moves it to Hedy, that save reports Ada as the previous watcher, and Grace, who held the book, is not reached. The save also overwrites a change it never saw, so reload an instance before saving it after another may have written the row.

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
