package Mojo::IRC::Server;
use Encode;
use Parse::IRC;
use Mojo::IOLoop;
use IRC::Utils qw(numeric_to_name name_to_numeric);
use POSIX ();
use List::Util qw(first);
use base qw(Mojo::Base Mojo::EventEmitter);
sub has { Mojo::Base::attr(__PACKAGE__, @_) }

has host => "0.0.0.0";
has port => 6667;
has network => "Mojo IRC NetWork";
has ioloop => sub { Mojo::IOLoop->singleton };
has parser => sub { Parse::IRC->new };
has servername => "irc.perfi.wang";
has create_time => sub{POSIX::strftime( '%Y/%m/%d %H:%M:%S', localtime() )};
has client => sub {[]};
has channel => sub {[]};

sub ready {
    my $s = shift;
    Mojo::IOLoop->server({host=>$s->host,port=>$s->port}=>sub{
        my ($loop, $stream) = @_;
        my $id = $stream->handle->sockhost . ":" . $stream->handle->sockport . ":" . $stream->handle->peerhost  . ":". $stream->handle->peerport;
        my $client = {
            id  =>$id,
            user=>undef,
            nick=>"*",
            mode=>undef,
            realname=>"irc.perfi.wang",
            stream=>$stream,
            buffer=>'',
            channel=>{},
        };
        $client->{stream}->timeout(0);
        $s->emit(new_client=>$client);
    });
    $s->on(new_client=>sub{
        my ($s,$client)=@_;
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
            elsif($msg->{command} eq "PART"){$s->emit(join=>$client,$msg)}
            elsif($msg->{command} eq "PING"){$s->emit(ping=>$client,$msg)} 
            elsif($msg->{command} eq "PONG"){$s->emit(pong=>$client,$msg)} 
            elsif($msg->{command} eq "MODE"){$s->emit(mode=>$client,$msg)} 
            elsif($msg->{command} eq "PRIVMSG"){$s->emit(privmsg=>$client,$msg)} 
            elsif($msg->{command} eq "QUIT"){$s->emit(quit=>$client,$msg)} 
        });
        $client->{stream}->on(error=>sub{
            my ($stream, $err) = @_;
            $s->emit(close_client=>$client);
        });
        $client->{stream}->on(close=>sub{
            my ($stream, $err) = @_;
            print "客户端 $client->{id} 退出\n";
            $s->emit(close_client=>$client);
        });
    });
    $s->on(close_client=>sub{
        my ($s,$client)=@_;
        $s->del_client($client);
    });

    $s->on(nick=>sub{
        my ($s,$client,$msg)=@_;
        my $nick = $msg->{params}[0];
        my $c = $s->search_client(nick=>$nick);
        if(defined $c and $c->{id} ne $client->{id}){
            $s->send($client,$s->servername,c2n("ERR_NICKNAMEINUSE"),$client->{nick},$nick,'昵称已经被使用');
            return;
        }
        if(defined $client->{nick}){
            $s->send($client,fullname($client),"NICK",$nick);
            $client->{nick} = $nick;
        }
        else{
            $client->{nick} = $nick;
        }
    });
    $s->on(user=>sub{
        my ($s,$client,$msg)=@_;
        $client->{user} = $msg->{params}[0];
        $client->{mode} = $msg->{params}[1]; 
        $client->{realname} = $msg->{params}[3]; 
        $s->send($client,$s->servername,"001",$client->{nick},"Welcome to the Mojo IRC Network " . fullname($client));
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
        $s->send($client,$s->servername,"396",$client->{nick},$s->servername,"is your displayed hostname now");

    });

    $s->on(join=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        $s->join_channel($client,$channel_id);
        $s->send($client,fullname($client),"JOIN",$channel_id);
        $s->send($client,$s->servername,c2n("RPL_NAMREPLY"),"*",$channel_id,"\=$client->{nick}");
        $s->send($client,$s->servername,c2n("RPL_ENDOFNAMES"),$client->{nick},$channel_id,"End of NAMES list");
        $s->send($client,$s->servername,c2n("RPL_CREATIONTIME"),$client->{nick},$channel_id,time());
    });

    $s->on(part=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        $s->part_channel($client,$channel_id);
    });

    $s->on(quit=>sub{
        my ($s,$client,$msg)=@_;
        my $quit_msg = $msg->{params}[0];
        $s->del_client($client);
    });
    $s->on(privmsg=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        my $content = $msg->{params}[1];
        print fullname($client),"|$channel_id :",$content,"\n";
        for (grep { $_->{channel}{$channel_id} } grep {$_->{id} ne $client->{id}} @{$s->client}){
            $s->send($_,fullname($client),"PRIVMSG",$channel_id,$content);
        }
    });
    $s->on(mode=>sub{
        my ($s,$client,$msg)=@_;
        my $channel_id = $msg->{params}[0];
        $s->send($client,$s->servername,c2n("RPL_CHANNELMODEIS"),$client->{nick},$channel_id,"+");
    });

    $s->on(ping=>sub{
        my ($s,$client,$msg)=@_;
        my $servername = $msg->{params}[0];
        $s->send($client,$s->servername,"PONG",,$s->servername,$servername);
    });

    $s->on(pong=>sub{
        my ($s,$client,$msg)=@_;
    });

}

sub c2n{
    name_to_numeric(@_);
}
sub n2c{
    numeric_to_name(@_);
}
sub fullname{
    my $client = shift;
    "$client->{nick}!$client->{user}\@$client->{realname}"; 
}

sub part_channel{
    my $s =shift;
    my $client = shift;
    my $channel_id = shift;
    delete $client->{channel}{$channel_id};
}
sub join_channel{
    my $s =shift;
    my $client = shift;
    my $channel_id = shift;
    $client->{channel}{$channel_id} = 1;
}
sub add_client{
    my $s = shift;  
    my $client = shift;
    my $c = $s->search_client(id=>$clent->{id});
    if(defined $c){$c = $client}
    else{push @{$s->client},$client;}
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

sub send {
    my $s = shift;
    my $client = shift;
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
    p $msg;
    $client->{stream}->write($msg);
}
sub run{
    my $s = shift;
    $s->ready();
    $s->ioloop->start unless $s->ioloop->is_running;
} 
1;
