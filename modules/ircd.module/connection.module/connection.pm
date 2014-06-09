# Copyright (c) 2009-14, Mitchell Cooper
#
# @name:            "ircd::connection"
# @package:         "connection"
# @description:     "represents a connection to the server"
# @version:         ircd->VERSION
# @no_bless:        1
# @preserve_sym:    1
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package connection;

use warnings;
use strict;
use 5.010;
use parent 'Evented::Object';

use Socket::GetAddrInfo;
use Scalar::Util 'weaken';

use utils qw(col conn conf match v notice);

our ($api, $mod, $me, $pool);

sub new {
    my ($class, $stream) = @_;
    return unless defined $stream;

    bless my $connection = {
        stream        => $stream,
        ip            => $stream->{write_handle}->peerhost,
        host          => $stream->{write_handle}->peerhost,
        localport     => $stream->{write_handle}->sockport,
        peerport      => $stream->{write_handle}->peerport,
        source        => $me->{sid},
        time          => time,
        last_response => time,
        wait          => 0
    }, $class;

    # two initial waits:
    # in clients - one for NICK, one for USER.
    # in servers - one for PASS, one for SERVER.
    $connection->reg_wait(2);

    return $connection;
}

sub handle {
    my ($connection, $data) = @_;

    $connection->{ping_in_air}   = 0;
    $connection->{last_response} = time;

    # connection is being closed
    return if $connection->{goodbye};

    # if this peer is registered, forward the data to server or user
    return $connection->{type}->handle($data) if $connection->{ready};

    my @args = split /\s+/, $data;
    return unless defined $args[0];

    given (uc shift @args) {

        when ('NICK') {

            # not enough parameters
            return $connection->wrong_par('NICK') if not defined $args[0];

            my $nick = col(shift @args);

            # nick exists
            if ($pool->lookup_user_nick($nick)) {
                $connection->sendme("433 * $nick :Nickname is already in use.");
                return
            }

            # invalid chars
            if (!utils::validnick($nick)) {
                $connection->sendme("432 * $nick :Erroneous nickname");
                return
            }

            # set the nick
            $connection->{nick} = $nick;
            $connection->reg_continue;

        }

        when ('USER') {

            # set ident and real name
            if (defined $args[3]) {
                $connection->{ident} //= ($connection->{tilde} ? '~' : '').$args[0];
                $connection->{real}    = col((split /\s+/, $data, 5)[4]);
                $connection->reg_continue;
            }

            # not enough parameters
            else {
                return $connection->wrong_par('USER')
            }

        }

        when ('SERVER') {

            # parameter check
            return $connection->wrong_par('SERVER') if not defined $args[4];


            $connection->{$_}   = shift @args foreach qw[sid name proto ircd];
            $connection->{desc} = col(join ' ', @args);

            # if this was by our request (as in an autoconnect or /connect or something)
            # don't accept any server except the one we asked for.
            if (exists $connection->{want} && lc $connection->{want} ne lc $connection->{name}) {
                $connection->done('unexpected server');
                return
            }

            # find a matching server
            if (defined ( my $addr = conn($connection->{name}, 'address') )) {

                # FIXME: we need to use IP comparison functions
                # check for matching IPs
                if ($connection->{ip} ne $addr) {
                    $connection->done('Invalid credentials');
                    notice(connection_invalid => $connection->{ip}, 'IP does not match block');
                    return;
                }

            }

            # no such server
            else {
                $connection->done('Invalid credentials');
                notice(connection_invalid => $connection->{ip}, 'No block for this server');
                return;
            }

            # made it.
            $connection->reg_continue;

        }

        when ('PASS') {

            # parameter check
            return $connection->wrong_par('PASS') if not defined $args[0];

            $connection->{pass} = shift @args;
            $connection->reg_continue;
            
        }

        when ('QUIT') {
            my $reason = 'leaving';

            # get the reason if they specified one
            if (defined $args[1]) {
                $reason = col((split /\s+/,  $data, 2)[1])
            }

            $connection->done("~ $reason");
        }

    }
}

# post-registration

sub wrong_par {
    my ($connection, $cmd) = @_;
    my $nick = $connection->{nick} // '*';
    $connection->sendme("461 $nick $cmd :Not enough parameters");
    return;
}

# increase the wait count.
sub reg_wait {
    my ($connection, $inc) = (shift, shift || 1);
    $connection->{wait} += $inc;
}

# decrease the wait count.
sub reg_continue {
    my ($connection, $inc) = (shift, shift || 1);
    $connection->ready unless $connection->{wait} -= $inc;
}

sub ready {
    my $connection = shift;

    # must be a user
    if (exists $connection->{nick}) {

        # if the client limit has been reached, hang up
        # FIXME: completely broken since pool creation. not sure what to do with this.
        #my $count = scalar grep { ($_->{type} || '')->isa('user') } values %connection;
        #if ($count >= conf('limit', 'client')) {
        #    $connection->done('Not accepting clients');
        #    return;
        #}
        
        $connection->{server}   =
        $connection->{location} = $me;
        $connection->{cloak}  //= $connection->{host};


        # create a new user.
        $connection->{type} = $pool->new_user(%$connection);
        
    }

    # must be a server
    elsif (exists $connection->{name}) {

        # check for valid password.
        my $password = utils::crypt($connection->{pass}, conn($connection->{name}, 'encryption'));

        if ($password ne conn($connection->{name}, 'receive_password')) {
            $connection->done('Invalid credentials');
            notice(connection_invalid => $connection->{ip}, 'Received invalid password');
            return;
        }
        
        # check if the server is linked already.
        if ($pool->lookup_server($connection->{sid}) || $pool->lookup_server_name($connection->{name})) {
            notice(connection_invalid => $connection->{ip}, 'Server exists');
            return;
        }

        $connection->{parent} = $me;
        $connection->{type}   = my $server = $pool->new_server(%$connection);
        $server->{conn}       = $connection;
        weaken($connection->{type}{location} = $connection->{type});
        $pool->fire_command_all(sid => $connection->{type});

        # send server credentials
        if (!$connection->{sent_creds}) {
            $connection->send(sprintf 'SERVER %s %s %s %s :%s',
                $me->{sid},
                $me->{name},
                v('PROTO'),
                v('VERSION'),
                $me->{desc}
            );
            $connection->send('PASS '.conn($connection->{name}, 'send_password'));
        }
        
        # I already sent mine, meaning it should have been accepted on both now.
        # go ahead and send the burst.
        else {
            $server->send_burst if !$server->{i_sent_burst};
        }
        
    }

    
    else {
        # must be an intergalactic alien
        warn 'intergalactic alien has been found';
    }
    
    weaken($connection->{type}{conn} = $connection);
    $connection->{type}->new_connection if $connection->{type}->isa('user');
    return $connection->{ready} = 1;
}

# send data to the socket
sub send {
    my ($connection, @msg) = @_;
    return unless $connection->{stream};
    return if $connection->{goodbye};
    $connection->{stream}->write("$_\r\n") foreach grep { defined } @msg;
}

# send data with a source
sub sendfrom {
    my ($connection, $source) = (shift, shift);
    $connection->send(map { ":$source $_" } @_);
}

# send data from ME
sub sendme {
    my $connection = shift;
    my $source =
        $connection->{type} && $connection->{type}->isa('server') ?
        $me->{sid} : $me->{name};
    $connection->sendfrom($source, @_);
}

sub sock {
    return shift->{stream}{read_handle};
}

# end a connection

sub done {
    my ($connection, $reason, $silent) = @_;
    return if $connection->{goodbye};
    
    L("Closing connection from $$connection{ip}: $reason");

    if ($connection->{type}) {
        # share this quit with the children
        $pool->fire_command_all(quit => $connection, $reason);

        # tell user.pm or server.pm that the connection is closed
        $connection->{type}->quit($reason)
    }
    $connection->send("ERROR :Closing Link: $$connection{host} ($reason)") unless $silent;

    # remove from connection list
    $pool->delete_connection($connection) if $connection->{pool};
    
    # will close it WHEN the buffer is empty
    $connection->{stream}->close_when_empty if $connection->{stream};

    # destroy these references, just in case.
    delete $connection->{type}{conn};
    delete $connection->{type};

    # prevent confusion if more data is received
    delete $connection->{ready};
    $connection->{goodbye} = 1;

    $connection->delete_all_events();
    return 1;
}

###########################
### CLIENT CAPABILITIES ###
###########################


# has client capability
sub has_cap {
    my ($connection, $flag) = @_;
    return $flag ~~ @{ $connection->{cap} }
}

# add client capability
sub add_cap {
    my $connection = shift;
    my @flags = grep { !$connection->has_cap($_) } @_;
    L("adding capability flags to $connection: @flags");
    push @{ $connection->{cap} }, @flags
}

# remove client capability
sub remove_cap {
    my $connection = shift;
    my @remove     = @_;
    my %r;
    L("removing capability flags from $connection: @remove");

    @r{@remove}++;

    my @new        = grep { !exists $r{$_} } @{ $connection->{cap} };
    $connection->{flags} = \@new;
}



sub DESTROY {
    my $connection = shift;
    L("$connection destroyed");
}

# get the IO object
sub obj {
    shift->{stream}{write_handle} # XXX select
}

$mod