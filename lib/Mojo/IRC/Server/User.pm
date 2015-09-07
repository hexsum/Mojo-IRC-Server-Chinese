package Mojo::IRC::Server::User;
use Mojo::IRC::Server::Base 'Mojo::IRC::Server::Object';
use List::Util qw(first);
has [qw(id name io)];
has user    => '*';
has pass    => undef;
has nick    => '*';
has mode    => 'i';
has buffer  => '';
has virtual => 0;
has host => sub{$_[0]->virtual?"virtualhost":"hidden"}; 
has port => sub{$_[0]->virtual?"virtualport":"hidden"}; 
has ctime => sub{time()};
has 'last_speek_time';
has channel => sub{[]};
has realname => 'unset';

sub is_virtual {
    $_[0]->virtual;
}
sub quit{
    my $s = shift;
    my $quit_reason = shift || "";
    $s->broadcast($s->ident,"QUIT",$quit_reason);
    $s->info("[" . $s->nick . "] 已退出($quit_reason)");
    $s->{_server}->remove_user($s);
}
sub ident{
    my $s = shift;
    return $s->nick . '!' . $s->user . '@' . $s->host;    
}
sub set_nick{
    my $s = shift;
    my $nick = shift;
    my $user = $s->search_user(nick=>$nick);
    if(defined $user and $user->id ne $s->id){
        if($user->is_virtual){
            $s->{_server}->remove_user($user);
            $s->once(close=>sub{$s->{_server}->add_user($user)});
            $s->broadcast($s->ident,NICK => $nick);
            $s->info("[" . $s->nick . "] 修改昵称为 [$nick]");
            $s->nick($nick);
            $s->name($nick);
        }
        else{
            $s->send($s->serverident,"433",$user->nick,$nick,'昵称已经被使用');
            $s->info("昵称 [$nick] 已经被使用");
        }
    }
    else{
        $s->broadcast($s->ident,NICK => $nick);
        $s->info("[" . $s->nick . "] 修改昵称为 [$nick]");
        $s->nick($nick);
        $s->name($nick);
    }
}
sub set_mode{
    my $s = shift;
    my $mode = shift;
    my %mode = map {$_=>1} split //,$s->mode;
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
    $s->mode(join "",keys %mode);
    $s->send($s->ident,"MODE",$s->nick,$mode);
    $s->info("[" . $s->nick . "] 模式设置为: " . $s->mode);
}
sub join_channel{
    my $s = shift;
    my $channel;
    $channel = ref($_[0]) eq "Mojo::IRC::Server::Channel"?$_[0]:$s->search_channel(id=>$_[0]);
    return if not defined $channel;
    if(not $s->is_join_channel($channel->id)){
        push @{$s->channel},$channel->id;
        $channel->add_user($s->id);
        $channel->broadcast($s->ident,"JOIN",$channel->name);
    }
    else{$s->send($s->ident,"JOIN",$channel->name);} 
    $s->send($s->serverident,"332",$s->nick,$channel->name,$channel->topic);
    $s->send($s->serverident,"353",$s->nick,'=',$channel->name,join " ",map {$_->nick} $channel->users);
    $s->send($s->serverident,"366",$s->nick,$channel->name,"End of NAMES list");
    #$s->send($s->serverident,"329",$s->nick,$channel->name,$channel->ctime);
    $s->info("[" . $s->name . "] 加入频道 " . $channel->name);
}
sub part_channel{
    my $s = shift;
    my $channel = ref($_[0]) eq "Mojo::IRC::Server::Channel"?$_[0]:$s->search_channel(id=>$_[0]);
    my $part_info = $_[1];
    return if not defined $channel;
    $channel->broadcast($s->ident,"PART",$channel->name,$part_info);
    for(my $i=0;$i<@{$s->channel};$i++){
        if($channel->id eq $s->channel->[$i]){
            splice @{$s->channel},$i,1;
            last;
        }
    }
    $channel->remove_user($s->id);
    $s->info("[" . $s->nick . "] 离开频道 " . $channel->name);
    
}
sub is_join_channel{
    my $s = shift;
    my $cid = ref($_[0]) eq "Mojo::IRC::Server::Channel"?$_[0]->id:$_[0];
    if(defined $cid){
        return (first {$cid eq $_} @{$s->channel})?1:0;    
    }
    else{
        return 0+@{$s->channel};
    }
}
sub forward{
    my $s = shift;
    for my $channel ($s->channels){
        for my $user ($channel->users){
            next if $user->id eq $s->id;
            $user->send(@_);
        }
    }
}

sub broadcast{
    my $s = shift; 
    $s->send(@_);
    for my $channel ($s->channels){
        for my $user ($channel->users){
            next if $user->id eq $s->id;
            $user->send(@_);
        }
    }
}
sub channels{
    my $s = shift;
    my @channels = ();
    for my $cid (@{$s->channel}){
        my $channel = $s->search_channel(id=>$cid);
        push @channels ,$channel if defined $channel;
    }
    return @channels;
}
sub each_channel{
    my $s = shift;
    my $callback = shift;
    return if not $s->is_join_channel();
    for my $cid (@{$s->channel}){
        my $channel = $s->search_channel(id=>$cid);
        $callback->($s,$channel,@_) if defined $channel; 
    }
}

sub send{
    my $s = shift;
    return if $s->is_virtual ;
    my($prefix,$command,@params)=@_;
    my $msg = "";
    $msg .= defined $prefix ? ":$prefix " : "";
    $msg .= $command;
    my $trail;
    $trail = pop @params;
    $msg .= " $_" for @params;
    $msg .= defined $trail ? " :$trail" : "";
    $msg .= "\r\n";
    $s->io->write($msg);
    $s->last_speek_time(time());
    $s->debug("S[".$s->name."] $msg");
}
sub is_localhost{
    my $s = shift;
    return 0 if $s->is_virtual;
    return 1 if $s->io->handle->peerhost eq "127.0.0.1";
}
1;
