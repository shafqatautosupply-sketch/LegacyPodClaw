/*
 * OCProviderRegistry.m
 * LegacyPodClaw - Multi-Provider Implementation
 *
 * All providers use the same pattern: HTTP POST to chat completion endpoint.
 * The only differences are URL, headers, and request body format.
 */

#import "ProviderRegistry.h"

#pragma mark - Base HTTP Provider (shared logic)

@interface _OCBaseProvider : NSObject {
    @public
    NSString *_providerId;
    NSString *_displayName;
    NSString *_apiKey;
    NSString *_baseURL;
    NSURLConnection *_conn;
    NSMutableData *_respData;
    NSMutableString *_sseBuf;
    OCProviderStreamBlock _onChunk;
    OCProviderCompletionBlock _onComplete;
}
- (void)_sendRequest:(NSMutableURLRequest *)req stream:(BOOL)stream
             onChunk:(OCProviderStreamBlock)onChunk completion:(OCProviderCompletionBlock)completion;
@end

@implementation _OCBaseProvider

- (void)dealloc {
    [_providerId release]; [_displayName release]; [_apiKey release];
    [_baseURL release]; [_respData release]; [_sseBuf release];
    [_onChunk release]; [_onComplete release];
    [super dealloc];
}

- (NSString *)providerId { return _providerId; }
- (NSString *)displayName { return _displayName; }
- (NSString *)apiKey { return _apiKey; }
- (void)setApiKey:(NSString *)k { [_apiKey release]; _apiKey = [k copy]; }
- (NSString *)baseURL { return _baseURL; }
- (void)setBaseURL:(NSString *)u { [_baseURL release]; _baseURL = [u copy]; }
- (BOOL)isConfigured { return _apiKey && [_apiKey length] > 0; }
- (void)cancel { [_conn cancel]; }
- (NSArray *)availableModels { return @[]; }

- (void)_sendRequest:(NSMutableURLRequest *)req stream:(BOOL)stream
             onChunk:(OCProviderStreamBlock)onChunk completion:(OCProviderCompletionBlock)completion {
    [_onChunk release]; _onChunk = [onChunk copy];
    [_onComplete release]; _onComplete = [completion copy];
    [_respData release]; _respData = [[NSMutableData alloc] initWithCapacity:4096];
    [_sseBuf release]; _sseBuf = [[NSMutableString alloc] init];

    [_conn cancel]; [_conn release];
    _conn = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:YES];
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
    if (_onChunk) {
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [_sseBuf appendString:chunk ?: @""];
        [chunk release];
        /* Parse SSE lines */
        NSArray *lines = [_sseBuf componentsSeparatedByString:@"\n"];
        [_sseBuf setString:[lines lastObject] ?: @""];
        for (NSUInteger i = 0; i < [lines count] - 1; i++) {
            NSString *line = [lines objectAtIndex:i];
            if ([line hasPrefix:@"data: "]) {
                NSString *json = [line substringFromIndex:6];
                if ([json isEqualToString:@"[DONE]"]) continue;
                NSDictionary *evt = [NSJSONSerialization JSONObjectWithData:
                    [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (evt) _onChunk(evt);
            }
        }
    } else {
        [_respData appendData:data];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    if (!_onChunk && _onComplete) {
        NSDictionary *r = [NSJSONSerialization JSONObjectWithData:_respData options:0 error:nil];
        _onComplete(r, nil);
    } else if (_onComplete) {
        _onComplete(nil, nil);
    }
    [_onChunk release]; _onChunk = nil;
    [_onComplete release]; _onComplete = nil;
}

- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {
    if (_onComplete) _onComplete(nil, error);
    [_onChunk release]; _onChunk = nil;
    [_onComplete release]; _onComplete = nil;
}

@end

#pragma mark - Anthropic

@implementation OCAnthropicProvider
- (instancetype)initWithApiKey:(NSString *)key {
    if ((self = [super init])) {
        ((_OCBaseProvider *)self)->_providerId = [@"anthropic" retain];
        ((_OCBaseProvider *)self)->_displayName = [@"Anthropic" retain];
        ((_OCBaseProvider *)self)->_apiKey = [key copy];
        ((_OCBaseProvider *)self)->_baseURL = [@"https://api.anthropic.com" retain];
    }
    return self;
}
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c
            completion:(OCProviderCompletionBlock)comp {
    NSString *url = [NSString stringWithFormat:@"%@/v1/messages", self.baseURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:120];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"2024-06-04" forHTTPHeaderField:@"anthropic-version"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"x-api-key"];
    NSMutableDictionary *body = [request mutableCopy];
    if (c) [body setObject:@YES forKey:@"stream"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [body release];
    [(_OCBaseProvider *)self _sendRequest:req stream:c!=nil onChunk:c completion:comp];
}
- (NSArray *)availableModels { return @[@"claude-opus-4-1", @"claude-sonnet-4-20250514", @"claude-haiku-3-5"]; }
@end

#pragma mark - OpenAI

@implementation OCOpenAIProvider
- (instancetype)initWithApiKey:(NSString *)key {
    if ((self = [super init])) {
        ((_OCBaseProvider *)self)->_providerId = [@"openai" retain];
        ((_OCBaseProvider *)self)->_displayName = [@"OpenAI" retain];
        ((_OCBaseProvider *)self)->_apiKey = [key copy];
        ((_OCBaseProvider *)self)->_baseURL = [@"https://api.openai.com" retain];
    }
    return self;
}
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c
            completion:(OCProviderCompletionBlock)comp {
    NSString *url = [NSString stringWithFormat:@"%@/v1/chat/completions", self.baseURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:120];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    NSMutableDictionary *body = [request mutableCopy];
    if (c) [body setObject:@YES forKey:@"stream"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [body release];
    [(_OCBaseProvider *)self _sendRequest:req stream:c!=nil onChunk:c completion:comp];
}
- (NSArray *)availableModels { return @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"o1", @"o3-mini"]; }
@end

#pragma mark - Google/Gemini

@implementation OCGoogleProvider
- (instancetype)initWithApiKey:(NSString *)key {
    if ((self = [super init])) {
        ((_OCBaseProvider *)self)->_providerId = [@"google" retain];
        ((_OCBaseProvider *)self)->_displayName = [@"Google" retain];
        ((_OCBaseProvider *)self)->_apiKey = [key copy];
        ((_OCBaseProvider *)self)->_baseURL = [@"https://generativelanguage.googleapis.com" retain];
    }
    return self;
}
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c
            completion:(OCProviderCompletionBlock)comp {
    NSString *model = [request objectForKey:@"model"] ?: @"gemini-2.5-flash";
    NSString *url = [NSString stringWithFormat:@"%@/v1beta/models/%@:generateContent?key=%@",
                     self.baseURL, model, self.apiKey];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:120];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    /* Convert messages to Gemini format */
    NSArray *msgs = [request objectForKey:@"messages"];
    NSMutableArray *contents = [NSMutableArray array];
    for (NSDictionary *m in msgs) {
        NSString *role = [[m objectForKey:@"role"] isEqualToString:@"assistant"] ? @"model" : @"user";
        [contents addObject:@{@"role": role, @"parts": @[@{@"text": [m objectForKey:@"content"] ?: @""}]}];
    }
    NSDictionary *body = @{@"contents": contents};
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [(_OCBaseProvider *)self _sendRequest:req stream:NO onChunk:nil completion:comp];
}
- (NSArray *)availableModels { return @[@"gemini-2.5-flash", @"gemini-2.5-pro", @"gemini-1.5-flash", @"gemini-1.5-pro"]; }
@end

#pragma mark - Ollama

@implementation OCOllamaProvider
- (instancetype)initWithBaseURL:(NSString *)url {
    if ((self = [super init])) {
        ((_OCBaseProvider *)self)->_providerId = [@"ollama" retain];
        ((_OCBaseProvider *)self)->_displayName = [@"Ollama" retain];
        ((_OCBaseProvider *)self)->_apiKey = [@"" retain];
        ((_OCBaseProvider *)self)->_baseURL = [url copy];
    }
    return self;
}
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c
            completion:(OCProviderCompletionBlock)comp {
    NSString *url = [NSString stringWithFormat:@"%@/api/chat", self.baseURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:300];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSMutableDictionary *body = [request mutableCopy];
    [body setObject:@(!c) forKey:@"stream"]; /* Ollama streams by default */
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [body release];
    [(_OCBaseProvider *)self _sendRequest:req stream:c!=nil onChunk:c completion:comp];
}
- (NSArray *)availableModels { return @[@"llama3.1", @"mistral", @"codellama", @"phi3"]; }
@end

#pragma mark - Groq, Together, OpenRouter, Mistral, Deepseek (OpenAI-compatible)

#define OPENAI_COMPAT_PROVIDER(CLASS, PID, DNAME, URL) \
@implementation CLASS \
- (instancetype)initWithApiKey:(NSString *)key { \
    if ((self = [super init])) { \
        ((_OCBaseProvider *)self)->_providerId = [@PID retain]; \
        ((_OCBaseProvider *)self)->_displayName = [@DNAME retain]; \
        ((_OCBaseProvider *)self)->_apiKey = [key copy]; \
        ((_OCBaseProvider *)self)->_baseURL = [@URL retain]; \
    } return self; \
} \
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c \
            completion:(OCProviderCompletionBlock)comp { \
    NSString *url = [NSString stringWithFormat:@"%@/v1/chat/completions", self.baseURL]; \
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] \
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:120]; \
    [req setHTTPMethod:@"POST"]; \
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; \
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"]; \
    NSMutableDictionary *body = [request mutableCopy]; \
    if (c) [body setObject:@YES forKey:@"stream"]; \
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]]; \
    [body release]; \
    [(_OCBaseProvider *)self _sendRequest:req stream:c!=nil onChunk:c completion:comp]; \
} \
@end

OPENAI_COMPAT_PROVIDER(OCGroqProvider, "groq", "Groq", "https://api.groq.com/openai")
OPENAI_COMPAT_PROVIDER(OCTogetherProvider, "together", "Together AI", "https://api.together.xyz")
OPENAI_COMPAT_PROVIDER(OCOpenRouterProvider, "openrouter", "OpenRouter", "https://openrouter.ai/api")
OPENAI_COMPAT_PROVIDER(OCMistralProvider, "mistral", "Mistral", "https://api.mistral.ai")
OPENAI_COMPAT_PROVIDER(OCDeepseekProvider, "deepseek", "Deepseek", "https://api.deepseek.com")

#pragma mark - Custom Provider

@implementation OCCustomProvider
- (instancetype)initWithBaseURL:(NSString *)url apiKey:(NSString *)key {
    if ((self = [super init])) {
        ((_OCBaseProvider *)self)->_providerId = [@"custom" retain];
        ((_OCBaseProvider *)self)->_displayName = [@"Custom" retain];
        ((_OCBaseProvider *)self)->_apiKey = [key copy];
        ((_OCBaseProvider *)self)->_baseURL = [url copy];
    }
    return self;
}
- (void)chatCompletion:(NSDictionary *)request onChunk:(OCProviderStreamBlock)c
            completion:(OCProviderCompletionBlock)comp {
    NSString *url = [NSString stringWithFormat:@"%@/v1/chat/completions", self.baseURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:120];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (self.apiKey) [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey]
                  forHTTPHeaderField:@"Authorization"];
    NSMutableDictionary *body = [request mutableCopy];
    if (c) [body setObject:@YES forKey:@"stream"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [body release];
    [(_OCBaseProvider *)self _sendRequest:req stream:c!=nil onChunk:c completion:comp];
}
@end

#pragma mark - Provider Registry

@interface OCProviderRegistry () { NSMutableDictionary *_providerMap; }
@end

@implementation OCProviderRegistry
- (instancetype)init {
    if ((self = [super init])) {
        _providerMap = [[NSMutableDictionary alloc] initWithCapacity:12];
        _defaultProviderId = [@"google" copy];
    }
    return self;
}
- (void)dealloc { [_providerMap release]; [_defaultProviderId release]; [super dealloc]; }

- (void)registerProvider:(id<OCModelProvider>)p { [_providerMap setObject:p forKey:[p providerId]]; }
- (void)removeProvider:(NSString *)pid { [_providerMap removeObjectForKey:pid]; }
- (id<OCModelProvider>)providerForId:(NSString *)pid { return [_providerMap objectForKey:pid]; }
- (id<OCModelProvider>)defaultProvider { return [_providerMap objectForKey:_defaultProviderId]; }
- (NSArray *)providers { return [_providerMap allValues]; }

- (id<OCModelProvider>)providerForModel:(NSString *)modelId {
    if (!modelId) return [self defaultProvider];
    /* Route by model prefix */
    if ([modelId hasPrefix:@"claude"]) return [_providerMap objectForKey:@"anthropic"];
    if ([modelId hasPrefix:@"gpt"] || [modelId hasPrefix:@"o1"] || [modelId hasPrefix:@"o3"])
        return [_providerMap objectForKey:@"openai"];
    if ([modelId hasPrefix:@"gemini"]) return [_providerMap objectForKey:@"google"];
    return [self defaultProvider];
}

- (void)chatCompletionWithFailover:(NSDictionary *)request
                           models:(NSArray *)modelIds
                          onChunk:(OCProviderStreamBlock)onChunk
                       completion:(OCProviderCompletionBlock)completion {
    /* Try each model until one succeeds */
    __block NSUInteger idx = 0;
    __block void(^tryNext)(void) = nil;
    
    tryNext = ^{
        if (idx >= [modelIds count]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"OCProviderRegistry"
                code:-1 userInfo:@{NSLocalizedDescriptionKey: @"All providers failed"}]);
            return;
        }
        
        NSString *modelId = [modelIds objectAtIndex:idx];
        id<OCModelProvider> provider = [self providerForModel:modelId];
        idx++;
        
        if (!provider || ![provider isConfigured]) {
            tryNext();
            return;
        }
        
        NSMutableDictionary *req = [request mutableCopy];
        [req setObject:modelId forKey:@"model"];
        
        [provider chatCompletion:req onChunk:onChunk completion:^(NSDictionary *r, NSError *e) {
            [req release];
            if (e) tryNext();
            else if (completion) completion(r, nil);
        }];
    };
    
    tryNext();
}

- (NSArray *)allAvailableModels {
    NSMutableArray *all = [NSMutableArray array];
    for (id<OCModelProvider> p in [_providerMap allValues]) {
        [all addObjectsFromArray:[p availableModels]];
    }
    return all;
}

@end
