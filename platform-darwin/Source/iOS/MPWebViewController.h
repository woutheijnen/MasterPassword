//==============================================================================
// This file is part of Master Password.
// Copyright (c) 2011-2017, Maarten Billemont.
//
// Master Password is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Master Password is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You can find a copy of the GNU General Public License in the
// LICENSE file.  Alternatively, see <http://www.gnu.org/licenses/>.
//==============================================================================

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

@interface MPWebViewController : UIViewController<WKNavigationDelegate>

@property(nonatomic) IBOutlet WKWebView *webView;
@property(nonatomic) IBOutlet UINavigationBar *webNavigationBar;
@property(nonatomic) IBOutlet UINavigationItem *webNavigationItem;

@property(nonatomic) NSURL *initialURL;

@end
