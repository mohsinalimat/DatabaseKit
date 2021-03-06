#import "DBIntrospection.h"
#import "NSString+DBAdditions.h"
#import <objc/runtime.h>

__attribute((overloadable)) SEL DBCapitalizedSelector(NSString *prefix, NSString *key, NSString *suffix)
{
    return NSSelectorFromString([NSString stringWithFormat:@"%@%@%@",
                                 prefix, [key db_stringByCapitalizingFirstLetter], suffix ?: @""]);
}

__attribute((overloadable)) SEL DBCapitalizedSelector(NSString *prefix, NSString *key)
{
    return NSSelectorFromString([NSString stringWithFormat:@"%@%@",
                                 prefix, [key db_stringByCapitalizingFirstLetter]]);
}

NSArray *DBClassesInheritingFrom(Class superclass)
{
    int numClasses = objc_getClassList(NULL, 0);
    Class allClasses[numClasses];
    objc_getClassList(allClasses, numClasses);

    NSMutableArray *classes = [NSMutableArray array];
    for(NSInteger i = 0; i < numClasses; i++) {
        Class kls = allClasses[i];
        const char *name = class_getName(kls);
        if(!name || name[0] < 'A' || name[0] > 'Z' || strncmp(name, "NSKVONotifying_", 15) == 0)
            continue;
        do {
            kls = class_getSuperclass(kls);
        } while(kls && kls != superclass);
        if(kls)
            [classes addObject:allClasses[i]];
    }
    return classes.count > 0
         ? classes
         : nil;
}

DBPropertyAttributes *DBAttributesForProperty(Class klass, objc_property_t property)
{
    unsigned int attrCount;
    objc_property_attribute_t *rawAttrs = property_copyAttributeList(property, &attrCount);

    Ivar ivar = NULL;
    BOOL dynamic = NO;
    BOOL atomic  = YES;
    BOOL readOnly = NO;
    Class propKlass = nil;
    BOOL hasProtocolList = NO;
    SEL getter = nil, setter = nil;
    DBMemoryManagementPolicy memoryManagementPolicy = DBPropertyStrong;
    size_t encodingLen = 0;
    int encodingIdx = -1;
    for(unsigned int i = 0; i < attrCount; ++i) {
        switch(*rawAttrs[i].name) {
            case 'R': readOnly = YES; break;
            case 'C': memoryManagementPolicy = DBPropertyCopy; break;
            case 'W': memoryManagementPolicy = DBPropertyWeak; break;
            case 'D': dynamic = YES; break;
            case 'N': atomic = NO; break;
            case 'G': getter = sel_registerName(rawAttrs[i].value); break;
            case 'S': setter = sel_registerName(rawAttrs[i].value); break;
            case 'V': ivar = class_getInstanceVariable(klass, rawAttrs[i].value); break;
            case 'T':
                encodingIdx = i;
                encodingLen = strlen(rawAttrs[i].value);
                if(rawAttrs[i].value[0] == _C_ID && rawAttrs[i].value[1] == '"') {
                    const char *classNameStart = rawAttrs[i].value + 2;
                    const char *classNameEnd   = strchr(classNameStart, '"');
                    if(classNameEnd) {
                        char className[classNameEnd - classNameStart + 1];
                        strncpy(className, classNameStart, sizeof(className)-1);
                        className[sizeof(className)-1] = '\0';
                        propKlass = objc_getClass(className);

                        // Protocols are listed like "Klass<Protocol1><Protocol2>"
                        char *protocolNames;
                        if(!propKlass && (protocolNames = strnstr(className, "<", sizeof(className)))) {
                            *protocolNames = '\0';
                            propKlass = objc_getClass(className);
                            hasProtocolList = YES;
                        }
                    }
                }
                break;
            default: break;
        }
    }
    DBPropertyAttributes *attrs = calloc(1, sizeof(DBPropertyAttributes) + encodingLen + 1);
    *attrs = (DBPropertyAttributes) {
        .name            = property_getName(property),
        .ivar            = dynamic ? NULL : ivar,
        .klass           = propKlass,
        .hasProtocolList = hasProtocolList,
        .dynamic         = dynamic,
        .atomic          = atomic,
        .memoryManagementPolicy = memoryManagementPolicy,
        .getter          = getter ?: sel_registerName(property_getName(property)),
        .setter          = readOnly
                         ? NULL
                         : setter ?: DBCapitalizedSelector(@"set", @(property_getName(property)), @":")
    };
    if(encodingIdx != -1)
        strncpy(attrs->encoding, rawAttrs[encodingIdx].value, encodingLen);
    attrs->encoding[encodingLen+1] = '\0';

    free(rawAttrs);
    return attrs;
}

void DBIteratePropertiesForClass(Class klass, void (^blk)(DBPropertyAttributes *))
{
    unsigned int propertyCount;
    objc_property_t * properties = class_copyPropertyList(klass, &propertyCount);
    for(unsigned int i = 0; i < propertyCount; ++i) {
        DBPropertyAttributes *attrs = DBAttributesForProperty(klass, properties[i]);
        blk(attrs);
        free(attrs);
    }
    if(class_getSuperclass(klass))
        DBIteratePropertiesForClass(class_getSuperclass(klass), blk);
}

NSArray *DBProtocolNamesInTypeEncoding(const char *encoding)
{
    NSCParameterAssert(encoding[0] == '@' && encoding[1] == '"');
    
    NSMutableArray *protocolNames = [NSMutableArray new];
    if((encoding = strnstr(encoding, "<", strlen(encoding)))) {
        while(encoding[0] == '<') {
            char protocolName[sizeof(char)*strlen(encoding)];
            int protocolNameLen;
            if(sscanf(encoding, "<%[^>]>%n", protocolName, &protocolNameLen) > 0) {
                [protocolNames addObject:@(protocolName)];
                encoding += protocolNameLen;
            }
        }
    }
    return protocolNames;
}

BOOL DBPropertyConformsToProtocol(DBPropertyAttributes *attributes, Protocol *protocol)
{
    if([attributes->klass conformsToProtocol:protocol])
        return YES;
    else if(attributes->hasProtocolList) {
        NSString *protocolName = NSStringFromProtocol(protocol);
        return [DBProtocolNamesInTypeEncoding(attributes->encoding) containsObject:protocolName];
    } else
        return NO;
}
