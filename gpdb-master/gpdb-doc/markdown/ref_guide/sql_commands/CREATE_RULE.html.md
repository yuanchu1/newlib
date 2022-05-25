# CREATE RULE 

Defines a new rewrite rule.

## <a id="section2"></a>Synopsis 

``` {#sql_command_synopsis}
CREATE [OR REPLACE] RULE <name> AS ON <event>
  TO <table_name> [WHERE <condition>] 
  DO [ALSO | INSTEAD] { NOTHING | <command> | (<command>; <command> 
  ...) }
```

## <a id="section3"></a>Description 

`CREATE RULE` defines a new rule applying to a specified table or view. `CREATE OR REPLACE RULE` will either create a new rule, or replace an existing rule of the same name for the same table.

The Greenplum Database rule system allows one to define an alternate action to be performed on insertions, updates, or deletions in database tables. A rule causes additional or alternate commands to be run when a given command on a given table is run. An `INSTEAD` rule can replace a given command by another, or cause a command to not be run at all. Rules can be used to implement SQL views as well. It is important to realize that a rule is really a command transformation mechanism, or command macro. The transformation happens before the execution of the command starts. It does not operate independently for each physical row as does a trigger.

`ON SELECT` rules must be unconditional `INSTEAD` rules and must have actions that consist of a single `SELECT` command. Thus, an `ON SELECT` rule effectively turns the table into a view, whose visible contents are the rows returned by the rule's `SELECT` command rather than whatever had been stored in the table \(if anything\). It is considered better style to write a `CREATE VIEW` command than to create a real table and define an `ON SELECT` rule for it.

You can create the illusion of an updatable view by defining `ON INSERT`, `ON UPDATE`, and `ON DELETE` rules to replace update actions on the view with appropriate updates on other tables. If you want to support `INSERT RETURNING` and so on, be sure to put a suitable `RETURNING` clause into each of these rules.

There is a catch if you try to use conditional rules for view updates: there must be an unconditional `INSTEAD` rule for each action you wish to allow on the view. If the rule is conditional, or is not `INSTEAD`, then the system will still reject attempts to perform the update action, because it thinks it might end up trying to perform the action on the dummy table of the view in some cases. If you want to handle all the useful cases in conditional rules, add an unconditional `DO INSTEAD NOTHING` rule to ensure that the system understands it will never be called on to update the dummy table. Then make the conditional rules non-`INSTEAD`; in the cases where they are applied, they add to the default `INSTEAD NOTHING` action. \(This method does not currently work to support `RETURNING` queries, however.\)

**Note:** A view that is simple enough to be automatically updatable \(see [CREATE VIEW](CREATE_VIEW.html)\) does not require a user-created rule in order to be updatable. While you can create an explicit rule anyway, the automatic update transformation will generally outperform an explicit rule.

## <a id="section4"></a>Parameters 

name
:   The name of a rule to create. This must be distinct from the name of any other rule for the same table. Multiple rules on the same table and same event type are applied in alphabetical name order.

event
:   The event is one of `SELECT`, `INSERT`, `UPDATE`, or `DELETE`.

table\_name
:   The name \(optionally schema-qualified\) of the table or view the rule applies to.

condition
:   Any SQL conditional expression \(returning boolean\). The condition expression may not refer to any tables except `NEW` and `OLD`, and may not contain aggregate functions. `NEW` and `OLD` refer to values in the referenced table. `NEW` is valid in `ON INSERT` and `ON UPDATE` rules to refer to the new row being inserted or updated. `OLD` is valid in `ON UPDATE` and `ON DELETE` rules to refer to the existing row being updated or deleted.

INSTEAD
:   `INSTEAD NOTHING` indicates that the commands should be run instead of the original command.

ALSO
:   `ALSO` indicates that the commands should be run in addition to the original command. If neither `ALSO` nor `INSTEAD` is specified, `ALSO` is the default.

command
:   The command or commands that make up the rule action. Valid commands are `SELECT`, `INSERT`, `UPDATE`, or `DELETE`. The special table names `NEW` and `OLD` may be used to refer to values in the referenced table. `NEW` is valid in `ON INSERT` and `ON``UPDATE` rules to refer to the new row being inserted or updated. `OLD` is valid in `ON UPDATE` and `ON DELETE` rules to refer to the existing row being updated or deleted.

## <a id="section5"></a>Notes 

You must be the owner of a table to create or change rules for it.

It is very important to take care to avoid circular rules. Recursive rules are not validated at rule create time, but will report an error at execution time.

## <a id="section6"></a>Examples 

Create a rule that inserts rows into the child table `b2001` when a user tries to insert into the partitioned parent table `rank`:

```
CREATE RULE b2001 AS ON INSERT TO rank WHERE gender='M' and 
year='2001' DO INSTEAD INSERT INTO b2001 VALUES (NEW.id, 
NEW.rank, NEW.year, NEW.gender, NEW.count);
```

## <a id="section7"></a>Compatibility 

`CREATE RULE` is a Greenplum Database language extension, as is the entire query rewrite system.

## <a id="section8"></a>See Also 

[ALTER RULE](ALTER_RULE.html)[DROP RULE](DROP_RULE.html), [CREATE TABLE](CREATE_TABLE.html), [CREATE VIEW](CREATE_VIEW.html)

**Parent topic:** [SQL Commands](../sql_commands/sql_ref.html)

