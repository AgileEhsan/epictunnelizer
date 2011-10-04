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

use Data::Dumper;

### This is a dummy package.
### You can use it to define your own proxy selector

sub setup_proxy_selector ($) {
	my $cfg = shift; 
	
	open(FD, "<", "proxy_selectors.cfg") || die "Proxy selector conf is not available";
	
	my $sat_proxies;
	
	my $i = 1;
	
	while (<FD>) {

		if ($_ = /(.+) (.+)\n/) {
			$sat_proxies->{$i}->{SERVER} = $1;			
			$sat_proxies->{$i}->{URI} = $2;
		}
		$i++;
	}
	
	close(FD);

	return $sat_proxies;
}

sub get_satellite_proxy ($$$) {
	my ($sat_proxies, $client_ip, $url_requested) = @_;

	$sat_proxies->{1}->{AUTH_TYPE} = "none";
	return ($sat_proxies->{1}, undef);
}

sub refresh_selector($$) {
	my $cfg = shift;
	my $selectors = shift;	

	return $selectors;
}

sub denied_message ($) {
	my $sat_proxy = shift;
	my $msg = "";
	
	$msg .= "HTTP/1.0 403 Forbidden\r\n";
	$msg .= "\r\n";
	$msg .= "<h1>The url is not allowed</h1>";
	$msg .= "<br><br>";
	$msg .= "<h3>Please contact with the system administrator</h3>";
	
	return $msg;
}
1;
