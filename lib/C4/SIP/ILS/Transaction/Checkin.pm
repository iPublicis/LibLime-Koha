#
# An object to handle checkin status
#

package ILS::Transaction::Checkin;

use warnings;
use strict;

# use POSIX qw(strftime);

use ILS;
use ILS::Transaction;

use C4::Circulation;
use C4::Debug;

our @ISA = qw(ILS::Transaction);

my %fields = (
    magnetic => 0,
    sort_bin => undef,
    collection_code  => undef,
    # 3M extensions:
    call_number      => undef,
    destination_loc  => undef,
    alert_type       => undef,  # 00,01,02,03,04 or 99
    hold_patron_id   => undef,
    hold_patron_name => "",
    hold             => undef,
);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new();                # start with an ILS::Transaction object

    foreach (keys %fields) {
        $self->{_permitted}->{$_} = $fields{$_};    # overlaying _permitted
    }

    @{$self}{keys %fields} = values %fields;        # copying defaults into object
    return bless $self, $class;
}

sub do_checkin {
    my $self = shift;
    my $branch = @_ ? shift : 'SIP2' ;
    my $barcode = $self->{item}->id;
    $debug and warn "do_checkin() calling AddReturn($barcode, $branch)";
    my ($return, $messages, $iteminformation, $borrower) = AddReturn($barcode, $branch);
    $debug and warn "AddReturn return value: $return";
    $self->alert(0);
    # ignoring messages: NotIssued, IsPermanent, WasLost, WasTransfered

    # biblionumber, biblioitemnumber, itemnumber
    # borrowernumber, reservedate, branchcode
    # cancellationdate, found, reservenotes, priority, timestamp

    if ($messages->{BadBarcode}) {
        $self->alert_type('99');
    }
    if ($messages->{wthdrawn}) {
        $self->alert_type('99');
    }
    if ($messages->{Wrongbranch}) {
        $self->destination_loc($messages->{Wrongbranch}->{Rightbranch});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{WrongTransfer}) {
        $self->destination_loc($messages->{WrongTransfer});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{NeedsTransfer}) {
        $self->destination_loc($iteminformation->{homebranch});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{ResFound}) {
        $self->hold($messages->{ResFound});
        $debug and warn "Item returned at $branch reserved at $messages->{ResFound}->{branchcode}";
        $self->alert_type(($branch eq $messages->{ResFound}->{branchcode}) ? '01' : '02');
        my $do_transfer;
        if ($branch eq $messages->{ResFound}->{branchcode}) {
            $self->alert_type('01');
            $self->screen_msg('Hold for patron');
        } else {
            $self->alert_type('02');
            $do_transfer = 1;
            $self->screen_msg('Hold for patron at ' . $messages->{ResFound}->{branchcode});
        }
        C4::Reserves::ModReserveAffect($messages->{ResFound}->{itemnumber},
            $messages->{ResFound}->{borrowernumber},
            $do_transfer,$messages->{ResFound}->{reservenumber});
        if ($do_transfer) {
            C4::Reserves::ModReserveMinusPriority(
                $messages->{ResFound}->{itemnumber},
                $messages->{ResFound}->{borrowernumber},
                $messages->{ResFound}->{biblionumber},
                $messages->{ResFound}->{reservenumber});
            C4::Items::ModItemTransfer($messages->{ResFound}->{itemnumber},
                $branch,
                $messages->{ResFound}->{branchcode});
        }
        # If item is already in transit to another branch, do not alert
        if (($branch ne $messages->{ResFound}->{branchcode}) &&
            ($messages->{ResFound}->{found} eq 'T')) {
          $debug and warn "Alert type set to undefined";
          $self->alert_type(undef);
          $self->screen_msg(undef);
        }
    }
    $self->alert(1) if defined $self->alert_type;  # alert_type could be "00", hypothetically
    $self->ok($return);
}

sub resensitize {
	my $self = shift;
	unless ($self->{item}) {
		warn "resensitize(): no item found in object to resensitize";
		return;
	}
	return !$self->{item}->magnetic_media;
}

sub patron_id {
	my $self = shift;
	unless ($self->{patron}) {
		warn "patron_id(): no patron found in object";
		return;
	}
	return $self->{patron}->id;
}

1;