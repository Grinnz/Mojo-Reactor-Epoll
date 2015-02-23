package Mojo::Reactor::Epoll;
use Mojo::Base 'Mojo::Reactor';

$ENV{MOJO_REACTOR} ||= 'Mojo::Reactor::Epoll';

use IO::Epoll qw(EPOLLERR EPOLLHUP EPOLLIN EPOLLOUT EPOLLPRI
	EPOLL_CTL_ADD EPOLL_CTL_MOD EPOLL_CTL_DEL
	epoll_create epoll_ctl epoll_wait);
use List::Util 'min';
use Mojo::Util qw(md5_sum steady_time);
use POSIX ();
use Time::HiRes 'usleep';

use constant DEBUG => $ENV{MOJO_REACTOR_EPOLL_DEBUG} || 0;

our $VERSION = '0.002';

sub DESTROY {
	my $epfd = delete shift->{epfd};
	POSIX::close($epfd) if $epfd;
}

sub again {
	my ($self, $id) = @_;
	my $timer = $self->{timers}{$id};
	$timer->{time} = steady_time + $timer->{after};
}

sub io {
	my ($self, $handle, $cb) = @_;
	my $fd = fileno $handle;
	$self->{io}{$fd}{cb} = $cb;
	warn "-- Set IO watcher for $fd\n" if DEBUG;
	return $self->watch($handle, 1, 1);
}

sub is_running { !!shift->{running} }

sub new {
	my $class = shift;
	my $self = $class->SUPER::new(@_);
	$self->{epfd} = $self->_epfd;
	return $self;
}

sub one_tick {
	my $self = shift;
	
	# Just one tick
	local $self->{running} = 1 unless $self->{running};
	
	# Wait for one event
	my $i;
	until ($i) {
		# Stop automatically if there is nothing to watch
		return $self->stop unless keys %{$self->{timers}} || keys %{$self->{io}};
		
		# Calculate ideal timeout based on timers
		my $min = min map { $_->{time} } values %{$self->{timers}};
		my $timeout = defined $min ? ($min - steady_time) : 0.5;
		$timeout = 0 if $timeout < 0;
		
		# I/O
		if (my $watched = keys %{$self->{io}}) {
			# Set max events to half the number of descriptors, to a minimum of 10
			my $maxevents = int $watched/2;
			$maxevents = 10 if $maxevents < 10;
			
			return $self->emit(error => "epoll_wait: $!") unless defined
				(my $res = epoll_wait($self->{epfd}, $maxevents, $timeout*1000));
			
			for my $ready (@$res) {
				my ($fd, $mode) = @$ready;
				if ($mode & (EPOLLIN | EPOLLPRI | EPOLLHUP | EPOLLERR)) {
					next unless exists $self->{io}{$fd};
					++$i and $self->_sandbox('Read', $self->{io}{$fd}{cb}, 0);
				}
				if ($mode & (EPOLLOUT | EPOLLHUP | EPOLLERR)) {
					next unless exists $self->{io}{$fd};
					++$i and $self->_sandbox('Write', $self->{io}{$fd}{cb}, 1);
				}
			}
		}
		
		# Wait for timeout if epoll can't be used
		elsif ($timeout) { usleep $timeout * 1000000 }
		
		# Timers (time should not change in between timers)
		my $now = steady_time;
		for my $id (keys %{$self->{timers}}) {
			next unless my $t = $self->{timers}{$id};
			next unless $t->{time} <= $now;
			
			# Recurring timer
			if (exists $t->{recurring}) { $t->{time} = $now + $t->{recurring} }
			
			# Normal timer
			else { $self->remove($id) }
			
			++$i and $self->_sandbox("Timer $id", $t->{cb}) if $t->{cb};
		}
	}
}

sub recurring { shift->_timer(1, @_) }

sub remove {
	my ($self, $remove) = @_;
	if (ref $remove) {
		my $fd = fileno $remove;
		if (exists $self->{io}{$fd}{in_epoll}) {
			return $self->emit(error => "epoll_ctl: $!") if
				epoll_ctl($self->{epfd}, EPOLL_CTL_DEL, $fd, 0) < 0;
		}
		warn "-- Removed IO watcher for $fd\n" if DEBUG;
		return !!delete $self->{io}{$fd};
	} else {
		warn "-- Removed timer $remove\n" if DEBUG;
		return !!delete $self->{timers}{$remove};
	}
}

sub reset {
	my $self = shift;
	my $epfd = delete $self->{epfd};
	POSIX::close($epfd) if $epfd;
	delete @{$self}{qw(io timers)};
	$self->{epfd} = $self->_epfd;
}

sub start {
	my $self = shift;
	$self->{running}++;
	$self->one_tick while $self->{running};
}

sub stop { delete shift->{running} }

sub timer { shift->_timer(0, @_) }

sub watch {
	my ($self, $handle, $read, $write) = @_;
	
	my $mode = 0;
	$mode |= EPOLLIN | EPOLLPRI if $read;
	$mode |= EPOLLOUT if $write;
	
	my $fd = fileno $handle;
	my $io = $self->{io}{$fd};
	my $op = exists $io->{in_epoll} ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
	
	return $self->emit(error => "epoll_ctl: $!") if
		epoll_ctl($self->{epfd}, $op, $fd, $mode) < 0;
	$io->{in_epoll} = 1;
	
	return $self;
}

sub _epfd {
	my $self = shift;
	my $epfd = epoll_create(15); # Size is ignored but must be > 0
	if ($epfd < 0) {
		if ($! =~ /not implemented/) {
			die "You need at least Linux 2.5.44 to use Mojo::Reactor::Epoll";
		} else {
			die "epoll_create: $!\n";
		}
	}
	return $epfd;
}

sub _id {
	my $self = shift;
	my $id;
	do { $id = md5_sum 't' . steady_time . rand 999 } while $self->{timers}{$id};
	return $id;
}

sub _io {
	my ($self, $fd, $writable) = @_;
	my $io = $self->{io}{$fd};
	#warn "-- Event fired for IO watcher $fd\n" if DEBUG;
	$self->_sandbox($writable ? 'Write' : 'Read', $io->{cb}, $writable);
}

sub _sandbox {
	my ($self, $event, $cb) = (shift, shift, shift);
	eval { $self->$cb(@_); 1 } or $self->emit(error => "$event failed: $@");
}

sub _timer {
	my ($self, $recurring, $after, $cb) = @_;
	
	my $id = $self->_id;
	my $timer = $self->{timers}{$id}
		= {cb => $cb, after => $after, time => steady_time + $after};
	$timer->{recurring} = $after if $recurring;
	
	if (DEBUG) {
		my $is_recurring = $recurring ? ' (recurring)' : '';
		warn "-- Set timer $id after $after seconds$is_recurring\n";
	}
	
	return $id;
}

=head1 NAME

Mojo::Reactor::Epoll - epoll backend for Mojo::Reactor

=head1 SYNOPSIS

  use Mojo::Reactor::Epoll;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::Epoll->new;
  $reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

  # Change to watching only if handle becomes writable
  $reactor->watch($handle, 0, 1);

  # Add a timer
  $reactor->timer(15 => sub {
    my $reactor = shift;
    $reactor->remove($handle);
    say 'Timeout!';
  });

  # Start reactor if necessary
  $reactor->start unless $reactor->is_running;

  # Or in an application using Mojo::IOLoop
  use Mojo::Reactor::Epoll;
  use Mojo::IOLoop;
  
  # Or in a Mojolicious application
  $ MOJO_REACTOR=Mojo::Reactor::Epoll hypnotoad script/myapp

=head1 DESCRIPTION

L<Mojo::Reactor::Epoll> is an event reactor for L<Mojo::IOLoop> that uses the
C<epoll(7)> Linux subsystem. The usage is exactly the same as other
L<Mojo::Reactor> implementations such as L<Mojo::Reactor::Poll>.
L<Mojo::Reactor::Epoll> will be used as the default backend for L<Mojo::IOLoop>
if it is loaded before L<Mojo::IOLoop> or any module using the loop. However,
when invoking a L<Mojolicious> application through L<morbo> or L<hypnotoad>,
the reactor must be set as the default by setting the C<MOJO_REACTOR>
environment variable to C<Mojo::Reactor::Epoll>.

=head1 EVENTS

L<Mojo::Reactor::Epoll> inherits all events from L<Mojo::Reactor>.

=head1 METHODS

L<Mojo::Reactor::Epoll> inherits all methods from L<Mojo::Reactor> and
implements the following new ones.

=head2 again

  $reactor->again($id);

Restart active timer.

=head2 io

  $reactor = $reactor->io($handle => sub {...});

Watch handle for I/O events, invoking the callback whenever handle becomes
readable or writable.

=head2 is_running

  my $bool = $reactor->is_running;

Check if reactor is running.

=head2 one_tick

  $reactor->one_tick;

Run reactor until an event occurs or no events are being watched anymore. Note
that this method can recurse back into the reactor, so you need to be careful.

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

Create a new recurring timer, invoking the callback repeatedly after a given
amount of time in seconds.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

Remove handle or timer.

=head2 reset

  $reactor->reset;

Remove all handles and timers.

=head2 start

  $reactor->start;

Start watching for I/O and timer events, this will block until L</"stop"> is
called or no events are being watched anymore.

=head2 stop

  $reactor->stop;

Stop watching for I/O and timer events.

=head2 timer

  my $id = $reactor->timer(0.5 => sub {...});

Create a new timer, invoking the callback after a given amount of time in
seconds.

=head2 watch

  $reactor = $reactor->watch($handle, $readable, $writable);

Change I/O events to watch handle for with true and false values. Note that
this method requires an active I/O watcher.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojolicious>, L<Mojo::IOLoop>, L<IO::Epoll>

=cut

1;
