- (void)_processSSEChunk:(NSString *)chunk {
    [_sseBuf appendString:chunk];
    NSArray *lines = [_sseBuf componentsSeparatedByString:@"\n"];
    [_sseBuf setString:[lines lastObject] ?: @""];

    /* Debug: show raw first chunk if nothing streaming yet */
    if ([_streamBuf length] == 0 && [chunk length] > 0 && [chunk length] < 200) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([_streamBuf length] == 0) {
                _typingDots.hidden = YES;
                _responseArea.textColor = [UIColor colorWithWhite:0.5f alpha:1];
                _responseArea.text = [NSString stringWithFormat:@"[receiving data...]"];
            }
        });
    }

    for (NSUInteger i = 0; i < [lines count] - 1; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        /* Skip empty lines */
        if ([trimmed length] == 0) continue;
        
        /* Handle SSE format (data: prefix) */
        NSString *json = nil;
        if ([trimmed hasPrefix:@"data: "]) {
            json = [trimmed substringFromIndex:6];
            if ([json isEqualToString:@"[DONE]"]) continue;
        } else {
            /* Handle raw JSON format (Google Gemini) */
            json = trimmed;
        }
        
        /* Try to parse JSON */
        NSDictionary *evt = [NSJSONSerialization JSONObjectWithData:
            [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (!evt) {
            NSLog(@"[LegacyPodClaw] Failed to parse JSON: %@", json);
            continue;
        }
        
        /* Extract text from Google's Gemini response structure */
        NSArray *candidates = [evt objectForKey:@"candidates"];
        if (candidates && [candidates count] > 0) {
            NSDictionary *candidate = [candidates objectAtIndex:0];
            NSDictionary *content = [candidate objectForKey:@"content"];
            NSArray *parts = [content objectForKey:@"parts"];
            if (parts && [parts count] > 0) {
                NSDictionary *part = [parts objectAtIndex:0];
                NSString *text = [part objectForKey:@"text"];
                if (text) {
                    [_streamBuf appendString:text];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        _typingDots.hidden = YES;
                        _responseArea.textColor = [UIColor colorWithWhite:0.88f alpha:1];
                        _responseArea.text = _streamBuf;
                    });
                }
            }
        }
    }
}
