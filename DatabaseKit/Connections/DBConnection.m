#import "DBConnection.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#define NOT_IMPLEMENTED [NSException raise:@"Unimplemented" format:@"DBConnection can not be used directly!"]

static NSMutableArray *_ConnectionClasses;

@interface DBConnection ()
@property(readwrite, retain) NSURL *URL;
@end

@implementation DBConnection
+ (BOOL)canHandleURL:(NSURL *)URL
{
    return NO;
}
+ (void)registerConnectionClass:(Class)kls
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _ConnectionClasses = [NSMutableArray array];
    });
    [_ConnectionClasses addObject:kls];
}
+ (id)openConnectionWithURL:(NSURL *)URL error:(NSError **)err
{
    if([URL isKindOfClass:[NSString class]])
        URL = [NSURL URLWithString:(NSString *)URL];
    for(Class kls in _ConnectionClasses) {
        if([kls canHandleURL:URL])
            return [[kls alloc] initWithURL:URL error:err];
    }
    if(err)
        *err = [NSError errorWithDomain:DBConnectionErrorDomain
                                   code:0
                               userInfo:@{ NSLocalizedDescriptionKey: @"Unhandled URL type", @"url": URL }];
    return nil;
}
- (id)initWithURL:(NSURL *)URL error:(NSError **)err
{
    if(!(self = [super init]))
        return nil;
    self.URL = URL;
    return self;
}
- (NSArray *)executeSQL:(NSString *)sql substitutions:(id)substitutions error:(NSError **)outErr
{
    NOT_IMPLEMENTED;
    return nil;
}
- (BOOL)closeConnection
{
    NOT_IMPLEMENTED;
    return NO;
}
- (BOOL)tableExists:(NSString *)tableName
{
    NOT_IMPLEMENTED;
    return NO;
}
- (NSDictionary *)columnsForTable:(NSString *)tableName
{
    NOT_IMPLEMENTED;
    return nil;
}
- (BOOL)beginTransaction
{
    NOT_IMPLEMENTED;
    return NO;
}
- (BOOL)rollBack
{
    NOT_IMPLEMENTED;
    return NO;
}
- (BOOL)endTransaction
{
    NOT_IMPLEMENTED;
    return NO;
}

- (BOOL)transaction:(DBTransactionBlock)aBlock
{
    @try {
        if(![self beginTransaction])
            return NO;
        switch(aBlock()) {
            case DBTransactionRollBack:
                return [self rollBack];
            case DBTransactionCommit:
                return [self endTransaction];
        }
    }
    @catch(NSException *_) {
        [self rollBack];
        return NO;
    }
    return YES;
}


#pragma mark -

+ (NSString *)sqlForType:(DBType)type
{
    switch(type) {
        case DBTypeInteger:
            return @"INTEGER";
        case DBTypeReal:
            return @"REAL";
        case DBTypeBoolean:
            return @"BOOL";
        case DBTypeText:
            return @"TEXT";
        case DBTypeBlob:
            return @"BLOB";
        default:
            return nil;
    }
}

+ (DBType)typeForSql:(NSString *)type
{
    type = [type uppercaseString];
    if([type isEqualToString:@"INTEGER"])
        return DBTypeInteger;
    else if([type isEqualToString:@"REAL"])
        return DBTypeReal;
    else if([type isEqualToString:@"BOOL"])
        return DBTypeBoolean;
    else if([type isEqualToString:@"TEXT"])
        return DBTypeText;
    else if([type isEqualToString:@"BLOB"])
        return DBTypeBlob;
    else
        return DBTypeUnknown;
}

+ (DBType)typeForObjCScalarEncoding:(char)encoding
{
    switch(encoding) {
        case _C_CHR:
        case _C_UCHR:
        case _C_SHT:
        case _C_USHT:
        case _C_INT:
        case _C_UINT:
        case _C_LNG:
        case _C_ULNG:
        case _C_LNG_LNG:
        case _C_ULNG_LNG:
            return DBTypeInteger;
        case _C_FLT:
        case _C_DBL:
            return DBTypeReal;
        case _C_BOOL:
            return DBTypeBoolean;
        default:
            return nil;
    }
}

+ (DBType)typeForClass:(Class)klass
{
    if([klass isSubclassOfClass:[NSData class]])
        return DBTypeBlob;
    else if([klass isSubclassOfClass:[NSString class]])
        return DBTypeText;
    else if([klass isSubclassOfClass:[NSNumber class]])
        return DBTypeReal;
    else
        return DBTypeUnknown;
}
@end
