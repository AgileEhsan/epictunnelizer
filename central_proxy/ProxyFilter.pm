#    __      _        _____                        _ _              
#   /__\ __ (_) ___  /__   \_   _ _ __  _ __   ___| (_)_______ _ __ 
#  /_\| '_ \| |/ __|   / /\/ | | | '_ \| '_ \ / _ \ | |_  / _ \ '__|
# //__| |_) | | (__   / /  | |_| | | | | | | |  __/ | |/ /  __/ |   
# \__/| .__/|_|\___|  \/    \__,_|_| |_|_| |_|\___|_|_/___\___|_|   
#     |_|                                                           
#
# http://sourceforge.net/projects/epictunnelizer/
#
# ============================================================================
#
# This project is an improvement of HTTPTunnelizer by Sebastian Weber, more info
# at: http://http-tunnel.sourceforge.net/
#
# Copyright (c) 2005-2011 Artica Soluciones Tecnologicas
# Please see http://sourceforge.net/projects/epictunnelizer/ for full contribution 
# list
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation; version 2
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

package main;

### This is a dummy package.
### You can use it to define your own url filters

sub setup_proxy_filters ($) {
	return 1;
}

sub url_allowed ($$$$) {
	return 1; #By default all url are allowed
	#return 0; #This url is not allowed
}

sub denied_message ($) {
	my $url = shift;
	my $msg = "";
	
	$msg .= "HTTP/1.0 403 Forbidden\r\n";
	$msg .= "\r\n";
	$msg .= "<h1>The url: $url is not allowed</h1>";
	$msg .= "<br><br>";
	$msg .= "<h3>Please contact with the system administrator</h3>";
	
	return $msg;
}
1;
