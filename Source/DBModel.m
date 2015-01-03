#import "DBModel+Private.h"
#import "DB+Private.h"
#import "DBSelectQuery.h"
#import "DBInsertQuery.h"
#import "DBDeleteQuery.h"
#import "DBTable.h"
#import "DBQuery.h"
#import "DBUtilities.h"
#import "NSString+DBAdditions.h"
#import "DBIntrospection.h"
#import "DBOrderedDictionary.h"
#import <objc/runtime.h>
#import <unistd.h>
#import <libkern/OSAtomic.h>

NSString * const kDBUUIDKey = @"UUID";

@implementation DBModel {
    DB *_database;
    DBOrderedDictionary *_pendingQueries;
    OSSpinLock _dbLock;
}
@dynamic saved, hasChanges;

+ (NSSet *)savedKeys
{
    static void *savedKeysKey = &savedKeysKey;

    if(self == [DBModel class])
        return nil;

    NSSet *savedKeys = objc_getAssociatedObject(self, savedKeysKey);
    if(!savedKeys) {
        NSSet *excludedKeys = [self excludedKeys];
        NSMutableSet *result = [NSMutableSet setWithObject:kDBUUIDKey];

        DBIteratePropertiesForClass(self, ^(DBPropertyAttributes *attrs) {
            NSString *key = @(attrs->name);
            if(!attrs->dynamic &&
               ![DBModel instancesRespondToSelector:attrs->getter] &&
               ![excludedKeys containsObject:key] &&
               (attrs->encoding[0] != _C_ID || [attrs->klass conformsToProtocol:@protocol(NSCoding)]))
                [result addObject:key];
        });
        savedKeys = result;
        objc_setAssociatedObject(self, savedKeysKey, result, OBJC_ASSOCIATION_RETAIN);
    }
    return [savedKeys count] > 0
         ? savedKeys
         : nil;
}

+ (NSSet *)excludedKeys
{
    return nil;
}

+ (NSArray *)indices
{
    return nil;
}

+ (NSArray *)constraintsForKey:(NSString *)key
{
    // Check if we respond to the selector `constraintsFor<Key>`
    SEL selector = DBCapitalizedSelector(@"constraintsFor", key);
    if([self respondsToSelector:selector]) {
        id (*imp)(id,SEL) = (void*)[self methodForSelector:selector];
        return imp(self, selector);
    } else
        return nil;
}

+ (NSArray *)constraintsForUUID
{
    return @[[DBPrimaryKeyConstraint primaryKeyConstraintWithOrder:DBOrderAscending
                                                     autoIncrement:NO
                                                        onConflict:DBConflictActionFail],
             [DBNotNullConstraint new]];
}


#pragma mark -

+ (NSSet *)keyPathsForValuesAffectingPendingQueries
{
    return [self savedKeys];
}

- (instancetype)init
{
    if((self = [super init])) {
        _dbLock = OS_SPINLOCK_INIT;
        self.UUID = [NSUUID UUID];
    }
    return self;
}

- (instancetype)initWithDatabase:(DB *)aDB result:(DBResult *)result
{
    NSParameterAssert(aDB);

    if((self = [self init])) {
        NSArray *columns = result.columns;
        for(NSUInteger i = 0; i < [columns count]; ++i) {
            id value = [result valueOfColumnAtIndex:i];
            if([value isKindOfClass:[NSData class]]) {
                DBPropertyAttributes *attrs = DBAttributesForProperty([self class],
                                                                      class_getProperty([self class], [columns[i] UTF8String]));
                if(attrs && attrs->encoding[0] == _C_ID && ![attrs->klass isSubclassOfClass:[NSData class]])
                    value = [NSKeyedUnarchiver unarchiveObjectWithData:value];
                free(attrs);
            }
            if([columns[i] isEqualToString:kDBUUIDKey])
                value = [[NSUUID alloc] initWithUUIDString:value];
            
            [self setValue:(value == [NSNull null]) ? nil : value
                    forKey:columns[i]];
        }
        _savedUUID = _UUID;

        self.database = aDB;
    }
    return self;
}

- (DB *)database
{
    OSSpinLockLock(&_dbLock);
    DB *db = _database;
    OSSpinLockUnlock(&_dbLock);
    return db;
}
- (void)setDatabase:(DB *)database
{
    OSSpinLockLock(&_dbLock);
    if(database != _database) {
        _database = database;
        if(_database) {
            _pendingQueries = [DBOrderedDictionary new];
            // This is to coerce KVC into calling didChangeValueForKey:
            // We don't actually take any action when pendingQueries changes
            [self addObserver:self
                   forKeyPath:@"pendingQueries"
                      options:0
                      context:NULL];
        } else {
            _pendingQueries = nil;
            _savedUUID = nil;
            [self removeObserver:self forKeyPath:@"pendingQueries"];
        }
    }
    OSSpinLockUnlock(&_dbLock);
}

- (void)didChangeValueForKey:(NSString *)key
{
    if(_database && _pendingQueries && [[[self class] savedKeys] containsObject:key]) {
        [self willChangeValueForKey:@"hasChanges"];
        _pendingQueries[key] = [self saveQueryForKey:key];
        [self didChangeValueForKey:@"hasChanges"];
        [self.database registerDirtyObject:self];
    }
    [super didChangeValueForKey:key];
}

- (void)dealloc
{
    self.database = nil; // Un-register KVO
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    // No action
}

- (id)valueForKey:(NSString *)key
{
    return [super valueForKey:key];
}
- (void)setValue:(id)value forKey:(NSString *)key
{
    [super setValue:value forKey:key];
}
- (void)setNilValueForKey:(NSString * const)aKey
{
    [self setValue:@0 forKey:aKey];
}

- (DBWriteQuery *)saveQueryForKey:(NSString *)key
{
    SEL selector = DBCapitalizedSelector(@"saveQueryFor", key);
    if([self respondsToSelector:selector]) {
        id (*imp)(id,SEL) = (void*)[self methodForSelector:selector];
        return imp(self, selector);
    } else if(!self.saved)
        return [self.query insert:@{ key: [self valueForKey:key] ?: [NSNull null] }];
    else
        return [self.query update:@{ key: [self valueForKey:key] ?: [NSNull null] }];
}

- (DBWriteQuery *)saveQueryForUUID
{
    if(!self.saved)
        return [self.query insert:@{ kDBUUIDKey: _UUID }];
    else
        return [self.query update:@{ kDBUUIDKey: _UUID }];
}

- (BOOL)_executePendingQueries:(NSError **)outErr
{
    NSAssert(_database, @"Tried to save object not in a database");

    if(!_savedUUID) {
        for(NSString *key in [[self class] savedKeys]) {
            if(!_pendingQueries[key])
                _pendingQueries[key] = [self saveQueryForKey:key];
        }
    }
    if(_pendingQueries.count == 0)
        return YES;
    
    for(DBWriteQuery *query in [DBQuery combineQueries:_pendingQueries.allValues]) {
        if(![query execute:outErr])
            return NO;
    }

    _savedUUID = self.UUID;
    [self willChangeValueForKey:@"hasChanges"];
    [_pendingQueries removeAllObjects];
    [self didChangeValueForKey:@"hasChanges"];
    return YES;
}

- (BOOL)isSaved
{
    return _savedUUID != nil;
}
- (BOOL)hasChanges
{
    return _pendingQueries.count > 0;
}

#pragma mark -

- (DBQuery *)query
{
    return [_database[[[self class] tableName]] where:@"%K = %@", kDBUUIDKey, _savedUUID ?: _UUID];
}

#pragma mark -

+ (NSString *)tableName
{
    static void *tableNameKey = &tableNameKey;
    NSString *tableName = objc_getAssociatedObject(self, tableNameKey);
    if(!tableName) {
        NSMutableString *builder = [NSStringFromClass(self) mutableCopy];
        NSUInteger dotLocation = [builder rangeOfString:@"."].location;
        if(dotLocation != NSNotFound)
            [builder deleteCharactersInRange:(NSRange) { 0, dotLocation+1 }];

        NSRange prefixRange = [builder rangeOfString:@"[A-Z]*" options:NSRegularExpressionSearch];
        if(prefixRange.location != 0 || NSMaxRange(prefixRange) == builder.length)
            return nil;
        else
            [builder deleteCharactersInRange:(NSRange) { 0, prefixRange.length-1 }];

        tableName = [[builder db_stringByDecapitalizingFirstLetter] db_pluralizedString];
        objc_setAssociatedObject(self, tableNameKey, tableName, OBJC_ASSOCIATION_RETAIN);
    }
    return tableName;
}

#pragma mark -

- (NSString *)description
{
    NSMutableString *description = [NSMutableString stringWithFormat:@"<%@:%p> (stored id: %@) {\n",
                                                                     [self class], self, self.savedUUID];
    for(NSString *key in [[self class] savedKeys]) {
        [description appendFormat:@"%@ = %@\n", key, [self valueForKey:key]];
    }
    [description appendString:@"}"];
    return description;
}

- (NSUInteger)hash
{
    return [_database[[[self class] tableName]] hash] ^ [_UUID hash];
}
- (BOOL)isEqual:(id)anObject
{
    return [anObject isMemberOfClass:[self class]]
        && self.database == [anObject database]
        && [self.UUID isEqual:[anObject UUID]];
}

- (instancetype)copyWithZone:(NSZone *)zone
{
    DBModel *copy = [[self class] new];
    for(NSString *column in [[self class] savedKeys]) {
        if(![column isEqualToString:kDBUUIDKey])
            [copy setValue:[self valueForKey:column] forKey:column];
    }
    return copy;
}

@end
