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

sub start_request_log ($) {
	
	my $cfg =shift;
	
	my $log_file = $cfg->{REQUESTS_LOG};	
	
	open(FD, ">", $log_file);	

	print FD "Request log started\n";
	
	close(FD);	
}

sub log_request ($$$;$) {
	
	my ($cfg, $ip, $url, $denied) = @_;
	
	my $log_file = $cfg->{REQUESTS_LOG};
		
	my $time = time();

	my @date = localtime($time);
			
	my $str_date = strftime("%d-%m-%Y %H:%M:%S", @date);
	
	my $log_str = $str_date." ".$ip." ".$url;
	
	#Denied possible values are: url or geolocation
	if (defined($denied)) {
		$log_str .= " ".$denied." denied";
	}
	
	open(FD, ">>", $log_file);
	
	print FD $log_str."\n";
	
	close(FD);
}
1;
