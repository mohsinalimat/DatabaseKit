#import "DBTable.h"
#import "DBModel.h"
#import "DBQuery.h"
#import "Utilities/NSString+DBAdditions.h"

@interface DBTable ()
@property(readwrite, strong) NSString *name;
@property(readwrite, strong) DB *database;
@end

@implementation DBTable

+ (DBTable *)withDatabase:(DB *)database name:(NSString *)name;
{
    DBTable *ret   = [self new];
    ret.database   = database;
    ret.name       = name;
    return ret;
}

- (Class)modelClass
{
    NSString *prefix    = [DBModel classPrefix];
    NSString *tableName = [[_name singularizedString] stringByCapitalizingFirstLetter];
    return NSClassFromString(prefix ? [prefix stringByAppendingString:tableName] : tableName);
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx
{
    return [[[[DBQuery withTable:self] select] limit:@1] where:@{ @"identifier": @(idx) }][0];
}

- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx
{
    [[[DBQuery withTable:self] update:obj] where:@{ @"identifier": @(idx) }];
}

- (id)objectForKeyedSubscript:(id)cond
{
    return [[[[DBQuery withTable:self] select] limit:@1] where:cond];
}

- (void)setObject:(id)obj forKeyedSubscript:(id)cond
{
    [[[DBQuery withTable:self] update:obj] where:cond];
}

- (NSString *)toString
{
    return _name;
}

- (BOOL)createIndex:(NSString *)name
                 on:(id)fields
            options:(NSUInteger)options
              error:(NSError **)err
{
    NSParameterAssert([fields isKindOfClass:[NSArray class]]
                      || [fields isKindOfClass:[NSString class]]);
    NSMutableString *query = [@"CREATE " mutableCopy];
    if(options & DBKeyOptionUnique)
        [query appendString:@"UNIQUE "];
    if(options & DBCreationOptionUnlessExists)
        [query appendString:@"INDEX IF NOT EXISTS "];
    else
        [query appendString:@"INDEX "];
    [query appendString:name];
    [query appendString:@" ON "];
    [query appendString:_name];
    [query appendString:@"("];
    if([fields isKindOfClass:[NSArray class]])
        [query appendString:[fields componentsJoinedByString:@", "]];
    else
        [query appendString:fields];
    [query appendString:@")"];

    return [_database.connection executeSQL:query substitutions:nil error:err] != nil;
}

- (NSArray *)columns
{
    return [_database.connection columnsForTable:_name];
}

#pragma mark - Query generators

- (DBSelectQuery *)select:(NSArray *)fields
{
    return [[DBQuery withTable:self] select:fields];
}
- (DBSelectQuery *)select
{
    return [[DBQuery withTable:self] select];
}

- (DBInsertQuery *)insert:(id)fields
{
    return [[DBQuery withTable:self] insert:fields];
}
- (DBUpdateQuery *)update:(id)fields
{
    return [[DBQuery withTable:self] update:fields];
}
- (DBDeleteQuery *)delete
{
    return [[DBQuery withTable:self] delete];
}
- (DBQuery *)where:(id)conds
{
    return [[DBQuery withTable:self] where:conds];
}
- (DBQuery *)order:(NSString *)order by:(id)fields
{
    return [[DBSelectQuery withTable:self] order:order by:fields];
}
- (DBQuery *)orderBy:(id)fields
{
    return [[DBSelectQuery withTable:self] orderBy:fields];
}
- (DBQuery *)limit:(NSNumber *)limit
{
    return [[DBSelectQuery withTable:self] limit:limit];
}
- (DBRawQuery *)rawQuery:(NSString *)SQL
{
    return [[DBQuery withTable:self] rawQuery:SQL];
}
- (NSUInteger)count
{
    return [[DBSelectQuery withTable:self] count];
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[DBTable class]]
        && [_name        isEqual:[(DBTable*)object name]]
        && _database == [(DBTable *)object database];
}

- (NSUInteger)hash
{
    return [_name hash] ^ [_database hash];
}

@end
