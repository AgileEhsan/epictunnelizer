<?php
//    __      _        _____                        _ _              
//   /__\ __ (_) ___  /__   \_   _ _ __  _ __   ___| (_)_______ _ __ 
//  /_\| '_ \| |/ __|   / /\/ | | | '_ \| '_ \ / _ \ | |_  / _ \ '__|
// //__| |_) | | (__   / /  | |_| | | | | | | |  __/ | |/ /  __/ |   
// \__/| .__/|_|\___|  \/    \__,_|_| |_|_| |_|\___|_|_/___\___|_|   
//     |_|                                                           
//
// http://sourceforge.net/projects/epictunnelizer/
//
// ============================================================================
//
// This project is an improvement of HTTPTunnelizer by Sebastian Weber, more info
// at: http://http-tunnel.sourceforge.net/
//
// Copyright (c) 2005-2011 Artica Soluciones Tecnologicas
// Please see http://sourceforge.net/projects/epictunnelizer/ for full contribution 
// list
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public License
// as published by the Free Software Foundation; version 2
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.

function request_log ($client_ip, $buf, $ctype, $dad, $dpo) {
        global $REQUESTS_LOG;

        if ($ctype == "CONNECT") {

                $line = date("d-m-Y H:i:s")." ".$client_ip." \"CONNECT $dad:$dpo\"";
        } else {

                $array = explode("\r\n", $buf);

                $resource = $array[0];

                $agent = "";

                foreach ($array as $a) {
                        $aux = explode (":", $a);

                        if ($aux[0] == "User-Agent") {
                                $agent = $aux[1];
                        }
                }
                //Example = 07-09-2011 09:20:11 127.0.0.1 "url" - "Agent"
                $line = date("d-m-Y H:i:s")." ".$client_ip." \"".$resource."\" \"".$agent."\"";
        }



        $fd=fopen ($REQUESTS_LOG, "a");
        if ($fd) {
                fwrite ($fd, $line."\r\n");
        }

        fclose($fd);
}

?>
