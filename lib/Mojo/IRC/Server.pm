package Mojo::IRC::Server;
$Mojo::IRC::Server::VERSION = "1.0.4";
use strict;
use Encode;
use Encode::Locale;
use Carp;
use Parse::IRC;
use Mojo::IOLoop;
use POSIX ();
use List::Util qw(first);
use Fcntl ':flock';
use base qw(Mojo::Base Mojo::EventEmitter);
sub has { Mojo::Base::attr(__PACKAGE__, @_) }

has host => "0.0.0.0";
has port => 6667;
has network => "Mojo IRC NetWork";
has ioloop => sub { Mojo::IOLoop->singleton };
has parser => sub { Parse::IRC->new };
has servername => "mojo-irc-server";
has clienthost => undef,
has create_time => sub{POSIX::strftime( '%Y/%m/%d %H:%M:%S', localtime() )};
has client => sub {[]};
has log_level => "info";
has log_path => undef;

has log => sub{
    require Mojo::Log;
    no warnings 'redefine';
    *Mojo::Log::append = sub{
        my ($self, $msg) = @_;
        return unless my $handle = $self->handle;
        flock $handle, LOCK_EX;
        $handle->print(encode("console_out", decode("utf8",$msg))) or $_[0]->die("Can't write to log: $!");
        flock $handle, LOCK_UN;
    };
    Mojo::Log->new(path=>$_[0]->log_path,level=>$_[0]->log_level,format=>sub{
        my ($time, $level, @lines) = @_;
        my $title="";
        if(ref $lines[0] eq "HASH"){
            my $opt = shift @lines; 
            $time = $opt->{"time"} if defined $opt->{"time"};
            $title = (defined $opt->{"title"})?$opt->{title} . " ":"";
            $level  = $opt->{level} if defined $opt->{"level"};
        }
        @lines = split /\n/,join "",@lines;
        my $return = "";
        $time = POSIX::strftime('[%y/%m/%d %H:%M:%S]',localtime($time));
        for(@lines){
            $return .=
                $time
            .   " " 
            .   "[$level]" 
            . " " 
            . $title 
            . $_ 
            . "\n";
        }
        return $return;
    });
};

sub ready {
    my $s = shift;
    $s->ioloop->server({host=>$s->host,port=>$s->port}=>sub{
        my ($loop, $stream) = @_;
        my $id = $stream->handle->sockhost . ":" . $stream->handle->sockport . ":" . $stream->handle->peerhost  . ":". $stream->handle->peerport;
        my $client = {
            id  =>  $id,
            name=>  $stream->handle->peerhost  . ":". $stream->handle->peerport,
            user=>  "",
            host=>  $stream->handle->peerhost,
            port=>  $stream->handle->peerport,
            nick=>  "*",
            mode=>  "i",
            stream  =>$stream,
            buffer  =>'',
            virtual =>0,
            channel =>{},
            realname =>"",
        };
        $client->{stream}->timeout(0);
        $s->emit(new_client=>$client);
    });

    $s->on(new_client=>sub{
        my ($s,$client)=@_;
        $s->debug("C[$client->{name}] 已连接");
        $s->add_client($client); 
        $client->{stream}->on(read=>sub{
            my($stream,$bytes) = @_;
            $bytes = $client->{buffer} . $bytes;
            my $pos = rindex($bytes,"\r\n");
            my $lines = substr($bytes,0,$pos);
            my $remains = substr($bytes,$pos+2);
            $client->{buffer} = $remains;
            $stream->emit(line=>$_) for split /\r\n/,$lines;
        });
        $client->{stream}->on(line=>sub{
            my($stream,$line)  = @_;
            my $msg = $s->parser->parse($line);
            $s->emit(client_msg=>$client,$msg);
            if($msg->{command} eq "PASS"){$s->emit(pass=>$client,$msg)}
            elsif($msg->{command} eq "NICK"){$s->emit(nick=>$client,$msg)}
            elsif($msg->{command} eq "USER"){$s->emit(user=>$client,$msg)}
            elsif($msg->{command} eq "JOIN"){$s->emit(join=>$client,$msg)}
            elsif($msg->{command} eq "PART"){$s->emit(part=>$client,$msg)}
            elsif($msg->{command} eq "PING"){$s->emit(ping=>$client,$msg)} 
            elsif($msg->{command} eq "PONG"){$s->emit(pong=>$client,$msg)} 
            elsif($msg->{command} eq "MODE"){$s->emit(mode=>$client,$msg)} 
            elsif($msg->{command} eq "PRIVMSG"){$s->emit(privmsg=>$client,$msg)} 
            elsif($msg->{command} eq "QUIT"){$s->emit(quit=>$client,$msg)} 
            elsif($msg->{command} eq "WHO"){$s->emit(who=>$client,$msg)} 
            elsif($msg->{command} eq "WHOIS"){$s->emit(who=>$client,$msg)} 
            elsif($msg->{command} eq "LIST"){$s->emit(list=>$client,$msg)} 
            elsif($msg->{command} eq "TOPIC"){$s->emit(topic=>$client,$msg)} 
        });
        $client->{stream}->on(error=>sub{
            my ($stream, $err) = @_;
            $s->emit(close_client=>$client);
            $s->debug("C[$client->{name}] 连接错误: $err");
        });
        $client->{stream}->on(close=>sub{
            my ($stream, $err) = @_;
            $s->emit(close_client=>$client);
        });
    });
    $s->on(client_msg=>sub{
        my ($s,$client,$msg)=@_;
        $s->debug("C[$client->{name}] $msg->{raw_line}");
    });
    $s->on(close_client=>sub{
        my ($s,$client)=@_;
        $s->del_client($client);
        $s->debug("C[$client->{name}] 已断开");
    });

    $s->on(nick=>sub{
        my ($s,$client,$msg)=@_;
        my $nick = $msg->{params}[0];
        $s->set_nick($client,$nick);
    });
    $s->on(user=>sub{
        my ($s,$client,$msg)=@_;
        if(defined $s->search_client(user=>$msg->{params}[0])){
            $s->send($client,$s->servername,"446",$client->{nick},"该帐号已被使用");
            return;
        }
        $client->{user} = $msg->{params}[0];
        #$client->{mode} = $msg->{params}[1]; 
        $client->{realname} = $msg->{params}[3]; 
        $s->send($client,$s->servername,"001",$client->{nick},"欢迎来到 Mojo IRC Network " . fullname($client));
        #$s->send($client,$s->servername,"002",$client->{nick},"Your host is " . $s->servername . ", running version Mojo-IRC-Server-1.0");
        #$s->send($client,$s->servername,"003",$client->{nick},"This server has been started " . $s->create_time);
        #$s->send($client,$s->servername,"004",$client->{nick},$s->servername . " Mojo-IRC-Server-1.0 abBcCFioqrRswx abehiIklmMnoOPqQrRstvVz");
        #$s->send($client,$s->servername,"005",$client->{nick},'RFC2812 IRCD=ngIRCd CHARSET=UTF-8 CASEMAPPING=ascii PREFIX=(qaohv)~&@%+ CHANTYPES=#&+ CHANMODES=beI,k,l,imMnOPQRstVz CHANLIMIT=#&+:10','are supported on this server');
        #$s->send($client,$s->servername,"251",$client->{nick},$s->servername,"There are 0 users and 0 services on 1 servers");
        #$s->send($client,$s->servername,"254",$client->{nick},$s->servername,0,"channels formed");
        #$s->send($client,$s->servername,"255",$client->{nick},$s->servername,"I have 0 users, 0 services and 0 servers");
        #$s->send($client,$s->servername,"265",$client->{nick},$s->servername,"is your displayed hostname now");
        #$s->send($client,$s->servername,"266",$client->{nick},$s->servername,"is your displayed hostname now");
        #$s->send($client,$s->servername,"250",$client->{nick},$s->servername,"is your displayed hostname now");
        #$s->send($client,$s->servername,"375",$client->{nick},$s->servername,"- ".$s->servername." message of the day");
        #$s->send($client,$s->servername,"372",$client->{nick},$s->servername,"- Welcome To Mojo IRC Server");
        #$s->send($client,$s->servername,"376",$client->{nick},$s->servername,"End of MOTD command");
        #$s->send($client,$s->servername,"396",$client->{nick},$s->servername,"是您当前显示的host名称");
        #$client->{host} = $s->servername;
    });

    $s->on(join=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        $s->join_channel($client,$channel_id);
    });

    $s->on(part=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        my $part_info = $msg->{params}[1];
        $s->part_channel($client,$channel_id,$part_info);
    });

    $s->on(quit=>sub{
        my ($s,$client,$msg)=@_;
        my $quit_reason = $msg->{params}[0];
        $s->quit($client,$quit_reason);
    });
    $s->on(privmsg=>sub{
        my ($s,$client,$msg)=@_;
        if(substr($msg->{params}[0],0,1) eq "#" ){
            my $channel_id = $msg->{params}[0];
            my $content = $msg->{params}[1];
            for (grep { exists $_->{channel}{$channel_id} } grep {$_->{id} ne $client->{id}} @{$s->client}){
                $s->send($_,fullname($client),"PRIVMSG",$channel_id,$content);
            }
            $s->info({level=>"频道消息",title=>"$client->{nick}|$channel_id :"},$content);
        }
        else{
            my $nick = $msg->{params}[0];
            my $content = $msg->{params}[1];
            my $c = $s->search_client(nick=>$nick);
            if(defined $c){
                #$s->send($client,fullname($client),"PRIVMSG",$nick,$content); 
                $s->send($c,fullname($client),"PRIVMSG",$nick,$content);
                $s->info({level=>"私信消息",title=>"[$client->{nick}]->[$nick] :"},$content);
            }
            else{
                $s->send($client,$s->servername,"401",$client->{nick},$nick,"No such nick")
            }
        }
    });
    $s->on(mode=>sub{
        my ($s,$client,$msg)=@_;
        if(substr($msg->{params}[0],0,1) eq "#" ){
            my $channel_id = $msg->{params}[0];
            my $channel_mode = $msg->{params}[1];
            if(defined $channel_mode){
                $s->set_channel_mode($client,$channel_id,$channel_mode);
            }
            else{
                $s->send($client,$s->servername,"324",$client->{nick},$channel_id,'+'.$client->{channel}{$channel_id}{mode});
            }
        }
        else{
            my $nick = $msg->{params}[0];
            my $mode = $msg->{params}[1];
            if(defined $mode){
                $s->set_user_mode($client,$mode);
            }
            else{
                $s->send($client,fullname($client),"MODE",$client->{nick},'+'.$client->{mode});
            }
        }
    });

    $s->on(ping=>sub{
        my ($s,$client,$msg)=@_;
        my $servername = $msg->{params}[0];
        $s->send($client,$s->servername,"PONG",,$s->servername,$servername);
    });

    $s->on(pong=>sub{
        my ($s,$client,$msg)=@_;
    });

    $s->on(who=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        for(grep {exists $_->{channel}{$channel_id}} @{$s->client}){
            $s->send($client,$s->servername,"352",$client->{nick},$channel_id,$_->{user},$_->{host},$s->servername,$_->{nick},"H","0 $_->{realname}"); 
        }
        $s->send($client,$s->servername,"315",$client->{nick},$channel_id,"End of WHO list");
    });
    $s->on(list=>sub{
        my ($s,$client,$msg)=@_;
        $s->each_channel(sub{
            my($s,$channel) = @_;
            return if $channel->{mode} =~/s/;
            $s->send($client,$s->servername,"322",$client->{nick},$channel->{name},$channel->{count},$channel->{topic});
        });
        $s->send($client,$s->servername,"323",$client->{nick},"End of LIST");
    });
    $s->on(topic=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0]; 
        my $topic = $msg->{params}[1];
        $s->set_channel_topic($client,$channel_id,$topic);
    });

}

sub set_nick {
    my $s = shift;
    my $client = shift;
    my $nick = shift;
    my $c = $s->search_client(nick=>$nick);
    if(defined $c and $c->{id} ne $client->{id}){
        $s->send($client,$s->servername,"433",$client->{nick},$nick,'昵称已经被使用');
        $s->info("昵称 [$nick] 已经被占用");
    }
    elsif($client->{nick} ne "*"){
        $s->change_nick($client,$nick);
    }
    else{
        $client->{nick} = $nick;
        $s->info("[$client->{name}] 设置昵称为 [$nick]");
    }
}

sub set_user_mode{
    my $s = shift;
    my $client = shift;
    my $mode = shift;
    my %mode = map {$_=>1} split //,$client->{mode};
    if(substr($mode,0,1) eq "+"){
        $mode{$_}=1 for  split //,substr($mode,1,); 
    }
    elsif(substr($mode,0,1) eq "-"){
        delete $mode{$_} for  split //,substr($mode,1,);
    }
    else{
        %mode = ();
        $mode{$_}=1 for  split //,$mode;
    }
    $client->{mode} = join "",keys %mode;
    $s->send($client,fullname($client),"MODE",$client->{nick},$mode);
    $s->info("[$client->{nick}] 模式设置为: $client->{mode}");
}
sub set_channel_mode{
    my $s = shift;
    my $client = shift;
    my $channel_id = shift;
    my $mode = shift;

    for my $c(@{$s->client}){
        if(exists $c->{channel}{$channel_id}){
            my %mode = map {$_=>1} split //,$c->{channel}{$channel_id}{mode};
            if(substr($mode,0,1) eq "+"){
                $mode{$_}=1 for  split //,substr($mode,1,);
            }
            elsif(substr($mode,0,1) eq "-"){
                delete $mode{$_} for  split //,substr($mode,1,);
            }
            else{
                %mode = ();
                $mode{$_}=1 for  split //,$mode;
            }            
            $c->{channel}{$channel_id}{mode} = join "",keys %mode;
        }
    }
    $s->send($client,$s->servername,"324",$client->{nick},$channel_id,$mode);
    $s->info("$channel_id 模式设置为: $client->{channel}{$channel_id}{mode}");
}

sub set_channel_topic{
    my $s = shift;
    my $client = shift;
    my $channel_id = shift;
    my $topic = shift;
    for my $c (@{$s->client}) {
        if(exists $c->{channel}{$channel_id}){
            $c->{channel}{$channel_id}{topic} = $topic;
        }
    }
    $s->send($client,fullname($client),"TOPIC",$channel_id,$topic);
    for my $c (grep {$client->{id} ne $_->{id}} @{$s->client}){
        $s->send($c,fullname($client),"TOPIC",$channel_id,$topic);
    }
    $s->info("$channel_id 主题设置为: $client->{channel}{$channel_id}{topic}");

}
sub fullname{
    shift if ref $_[0] eq __PACKAGE__;
    my $client = shift;
    "$client->{nick}!$client->{user}\@$client->{host}"; 
}

sub quit{
    my $s =shift;
    my $client = shift;
    my $quit_reason = shift;
    for my $c (grep {$client->{id} ne $_->{id}} @{$s->client}){
        for my $channel_id (keys %{$client->{channel}}){
            if(exists $c->{channel}{$channel_id}){
                $s->send($c,fullname($client),"QUIT",$quit_reason);
            }
        }
    }
    $s->info("[$client->{nick}] 已退出($quit_reason)");
    $s->del_client($client);
}
sub change_nick{
    my $s = shift;
    my $client = shift;
    my $nick = shift;
    $s->send($client,fullname($client),"NICK",$nick);
    for my $c (grep {$_->{id} ne $client->{id}} @{$s->{client}}){
        for my $channel_id (keys %{$client->{channel}}){
            if(exists $c->{channel}{$channel_id}){
                $s->send($c,fullname($client),"NICK",$nick);
            }
        }
    }
    $s->info("[$client->{nick}] 修改昵称为 [$nick]");
    $client->{nick} = $nick;
}

sub part_channel{
    my $s =shift;
    my $client = shift;
    my $channel_id = shift;
    my $part_info = shift;
    delete $client->{channel}{$channel_id};
    $s->send($client,fullname($client),"PART",$channel_id,$part_info);
    for (grep { exists $_->{channel}{$channel_id} } grep {$_->{id} ne $client->{id}} @{$s->{client}}){
        $s->send($_,fullname($client),"PART",$channel_id,$part_info);
    }
    $s->info("[$client->{nick}] 离开频道 $channel_id");
}
sub join_channel{
    my $s =shift;
    my $client = shift;
    my $channels = shift;
    my %opt = @_;
    for my $channel_id (split /,/,$channels){
        $channel_id = "#".$channel_id if substr($channel_id,0,1) ne "#";
        my $id = $opt{id} || $channel_id;
        my $mode = $opt{mode} || "i";
        my $channel = $s->search_channel(id=>$id);
        if(defined $channel){
            $client->{channel}{$channel_id} = {
                name=>  $channel->{name},
                id=>    $channel->{id},
                mode=>  $channel->{mode},
                topic=> $channel->{topic},
                ctime=> $channel->{ctime}
            };
        }
        else{
            $client->{channel}{$channel_id} = {
                name=>$channel_id,
                id=>$id,
                mode=>$mode,
                topic=>"欢迎来到频道 $channel_id",
                ctime=>time()
            };
        }   
        $s->send($client,fullname($client),"JOIN",$channel_id);
        $s->send($client,$s->servername,"332",$client->{nick},$channel_id,$client->{channel}{$channel_id}{topic});
        $s->send($client,$s->servername,"353",$client->{nick},"=",$channel_id,join(" ",map {$_->{nick}} grep {exists $_->{channel}{$channel_id}}  @{$s->client}));
        $s->send($client,$s->servername,"366",$client->{nick},$channel_id,"End of NAMES list");
        $s->send($client,$s->servername,"329",$client->{nick},$channel_id,$client->{channel}{$channel_id}{ctime} || time());

        for( grep {exists $_->{channel}{$channel_id}} grep {$_->{id} ne $client->{id}} @{$s->client}){
            $s->send($_,fullname($client),"JOIN",$channel_id);
        }
        $s->info("[$client->{nick}] 加入频道 $channel_id");
        if(ref $opt{cb} eq "CODE"){$opt{cb}->($s,$client)}
    }
}
sub add_client{
    my $s = shift;  
    my $client = shift;
    my $c = $s->search_client(id=>$client->{id});
    if(defined $c){$c = $client}
    else{push @{$s->client},$client;}
}

sub add_virtual_client {
    my $s = shift;
    my %opt = @_;
    my $c = $s->search_client(id=>$opt{id});
    return $c if defined $c;
    $opt{nick} =~s/\s+/_/g;
    $opt{nick} = '未知昵称' if not $opt{nick};
    while(1){
        my $c = $s->search_client(nick=>$opt{nick});
        if(defined $c){
            if($c->{nick}=~/\((\d+)\)$/){
                my $num = $1;$num++;
                $opt{nick} = $opt{nick} . "($num)";
            }
            else{
                $opt{nick} = $opt{nick} . "(1)";
            }   
        }
        else{last}
    }
    my $virtual_client = {
        id      => $opt{id},
        name    => $opt{name},
        user    => $opt{user},
        host    => $opt{host} || "virtualhost",
        port    => $opt{port} || "virtualport",
        nick    => $opt{nick},
        ctime   => time(),
        virtual => 1,
        mode    => "i",
        realname => "",
    };
    $s->add_client($virtual_client);
    return $virtual_client;
}
sub del_client{
    my $s = shift;
    my $client = shift;
    for(my $i=0;$i<@{$s->client};$i++){
        if($client->{id} eq $s->client->[$i]->{id}){
            splice @{$s->client},$i,1;
            return;
        }
    }
}

sub search_client {
    my $s = shift;
    my %p = @_;
    return if 0 == grep {defined $p{$_}} keys %p;
    if(wantarray){
        return grep {my $c = $_;(first {$p{$_} ne $c->{$_}} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->client};
    }
    else{
        return first {my $c = $_;(first {$p{$_} ne $c->{$_}} grep {defined $p{$_}} keys %p) ? 0 : 1;} @{$s->client};
    }
}

sub each_channel {
    my $s = shift;
    my $callback = shift;
    my %channel;
    for my $c (@{$s->client}){
        for my $channel_id (keys %{$c->{channel}}){
            if(exists $channel{$channel_id}){
                $channel{$channel_id}{count}++;
            }
            else{
                $channel{$channel_id} = {
                    id      =>$c->{channel}{$channel_id}{id},
                    ctime   =>$c->{channel}{$channel_id}{ctime},
                    topic   =>$c->{channel}{$channel_id}{topic} ,
                    count   =>1,
                    mode    =>$c->{channel}{$channel_id}{mode},
                    name    =>$c->{channel}{$channel_id}{name},
                };
            }
        }
    }

    for(values %channel){
        $callback->($s,$_);
    }
}

sub search_channel {
    my $s = shift;
    my %p = @_;
    return if 0 == grep {defined $p{$_}} keys %p;
    my %channel;
    for my $c (@{$s->client}){
        for my $channel_id (keys %{$c->{channel}}){
            if(exists $channel{$channel_id}){
                $channel{$channel_id}{count}++;
            }
            else{
                $channel{$channel_id} = {
                    id      =>$c->{channel}{$channel_id}{id},
                    ctime   =>$c->{channel}{$channel_id}{ctime},
                    topic   =>$c->{channel}{$channel_id}{topic} ,
                    count   =>1,
                    mode    =>$c->{channel}{$channel_id}{mode},
                    name    =>$c->{channel}{$channel_id}{name}
                };
            }
        }
    }
    if(wantarray){
        return grep {my $c = $_;(first {$p{$_} ne $c->{$_}} grep {defined $p{$_}} keys %p) ? 0 : 1;} values %channel;
    }
    else{
        return first {my $c = $_;(first {$p{$_} ne $c->{$_}} grep {defined $p{$_}} keys %p) ? 0 : 1;} values %channel;
    } 

}

sub send {
    my $s = shift;
    my $client = shift;
    return if $client->{virtual} ;
    my($prefix,$command,@params)=@_;
    my $msg = "";
    #$msg .= defined $prefix ? ":$prefix " : ":" . $s->servername . " ";
    $msg .= defined $prefix ? ":$prefix " : "";
    $msg .= "$command";
    my $trail;
    #if ( @params >= 2 ) {
        $trail = pop @params;
    #}
    map { $msg .= " $_" } @params;
    $msg .= defined $trail ? " :$trail" : "";
    $msg .= "\r\n";
    $client->{stream}->write($msg);
    $s->debug("S[$client->{name}] $msg");
}
sub run{
    my $s = shift;
    $s->ready();
    $s->ioloop->start unless $s->ioloop->is_running;
} 


sub timer{
    my $s = shift;
    $s->ioloop->timer(@_);
}
sub interval{
    my $s = shift;
    $s->ioloop->recurring(@_);
}

sub die{
    my $s = shift; 
    local $SIG{__DIE__} = sub{$s->log->fatal(@_);exit -1};
    Carp::confess(@_);
}
sub info{
    my $s = shift;
    $s->log->info(@_);
    $s;
}
sub warn{
    my $s = shift;
    $s->log->warn(@_);
    $s;
}
sub error{
    my $s = shift;
    $s->log->error(@_);
    $s;
}
sub fatal{
    my $s = shift;
    $s->log->fatal(@_);
    $s;
}
sub debug{
    my $s = shift;
    $s->log->debug(@_);
    $s;
}
1;
